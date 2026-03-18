#!/bin/bash

set -e

# Script to profile the multi-object weak reference benchmark once with perf and generate a function-level report

# Default values
JAVA_BIN="./build/linux-x86_64-server-release/jdk/bin/java"
JCMD_BIN="./build/linux-x86_64-server-release/jdk/bin/jcmd"
COMMON_JVM_OPTS="${COMMON_JVM_OPTS:--Xms10g -Xmx10g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:ZCollectionIntervalMajor=0.5 -XX:+ZCollectionIntervalOnly -XX:+UnlockDiagnosticVMOptions -XX:NativeMemoryTracking=summary}"
BENCHMARK_CLASS="test/weakrefs/WeakRefMultiObjectBenchmark.java"
CPU_CORES="${CPU_CORES:-0-11}"
MONITOR_CPU_CORES="${MONITOR_CPU_CORES:-12-19}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"

# Perf settings
PERF_SAMPLING_FREQ="${PERF_SAMPLING_FREQ:-99}"
PERF_EVENT="${PERF_EVENT:-cycles}"

# Check if perf is available
if ! command -v perf >/dev/null 2>&1; then
    echo "Error: perf is not installed. Install it with: sudo apt-get install linux-tools-generic"
    exit 1
fi

# Check for libperf-jvmti.so
LIBPERF_JVMTI=""
for path in /usr/lib64/libperf-jvmti.so /usr/lib/x86_64-linux-gnu/libperf-jvmti.so /usr/lib/libperf-jvmti.so; do
    if [ -f "$path" ]; then
        LIBPERF_JVMTI="$path"
        break
    fi
done

if [ -z "$LIBPERF_JVMTI" ]; then
    echo "Warning: libperf-jvmti.so not found in standard locations"
    echo "  Java code symbols may not be properly resolved in perf report"
    echo "  Install with: sudo apt-get install openjdk-*-dbg or build from source"
fi

# Ensure script runs on monitor cores so Java runs on worker cores
if [ -z "$SCRIPT_PINNED" ]; then
    export SCRIPT_PINNED=1
    exec taskset -c "$MONITOR_CPU_CORES" env SCRIPT_PINNED=1 bash "$0" "$@"
else
    echo "Script is pinned to CPU cores $MONITOR_CPU_CORES"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

print_step() { echo -e "${YELLOW}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Parse command line arguments
GA_ENABLED="${1:-ON}"
if [ "$GA_ENABLED" != "ON" ] && [ "$GA_ENABLED" != "OFF" ]; then
    echo "Usage: $0 [ON|OFF]"
    echo "  ON  - Run with growable array discovery enabled (default)"
    echo "  OFF - Run with growable array discovery disabled"
    exit 1
fi

print_header "WEAKREF GC BENCHMARK PROFILING (GA $GA_ENABLED)"
echo -e "${BOLD}CPU cores:${NC} $CPU_CORES"
echo -e "${BOLD}Perf sampling:${NC} $PERF_SAMPLING_FREQ Hz"
echo -e "${BOLD}Perf event:${NC} $PERF_EVENT"
if [ -n "$LIBPERF_JVMTI" ]; then
    echo -e "${BOLD}JIT symbols:${NC} enabled ($LIBPERF_JVMTI)"
else
    echo -e "${BOLD}JIT symbols:${NC} disabled (install libperf-jvmti)"
fi
echo -e "${BOLD}Cooldown:${NC} ${COOLDOWN_SECONDS}s before profiling"
echo ""

# Variable to store original CPU governor/freq
ORIGINAL_CPU_GOVERNOR=""
ORIGINAL_MIN_FREQ=""
ORIGINAL_MAX_FREQ=""

prepare_environment() {
    print_step "Preparing environment..."

    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo "  Dropping filesystem caches..."
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    else
        print_warning "  Skipping cache drop (no sudo access)"
    fi

    echo "  Cooldown period (${COOLDOWN_SECONDS}s)..."
    sleep "$COOLDOWN_SECONDS"

    print_success "Environment prepared"
}

setup_cpu_performance() {
    if command -v cpupower >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        ORIGINAL_CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")
        ORIGINAL_MIN_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "")
        ORIGINAL_MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "")

        print_step "Setting CPU governor to performance mode..."
        sudo cpupower frequency-set -g performance >/dev/null 2>&1 || print_warning "Could not set CPU governor"

        base_freq=""
        if [ -r "/sys/devices/system/cpu/cpu0/cpufreq/base_frequency" ]; then
            base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null || true)
        fi
        if [ -z "$base_freq" ] && [ -r "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq" ]; then
            base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || true)
        fi

        if [ -n "$base_freq" ]; then
            print_step "Setting scaling_min_freq/scaling_max_freq to base frequency ${base_freq} kHz..."
            for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
                if [ -d "$cpu_dir" ]; then
                    echo "$base_freq" | sudo tee "$cpu_dir/scaling_min_freq" >/dev/null 2>&1 || true
                    echo "$base_freq" | sudo tee "$cpu_dir/scaling_max_freq" >/dev/null 2>&1 || true
                fi
            done
            print_success "CPU frequencies set to base clock"
        else
            print_warning "Could not determine base CPU frequency; skipping min/max freq set"
        fi
    fi
}

restore_cpu_governor() {
    if command -v cpupower >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        if [ -n "$ORIGINAL_MIN_FREQ" ] && [ -n "$ORIGINAL_MAX_FREQ" ]; then
            print_step "Restoring CPU min/max frequencies..."
            for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
                if [ -d "$cpu_dir" ]; then
                    echo "$ORIGINAL_MIN_FREQ" | sudo tee "$cpu_dir/scaling_min_freq" >/dev/null 2>&1 || true
                    echo "$ORIGINAL_MAX_FREQ" | sudo tee "$cpu_dir/scaling_max_freq" >/dev/null 2>&1 || true
                fi
            done
        fi

        if [ -n "$ORIGINAL_CPU_GOVERNOR" ]; then
            print_step "Restoring CPU governor to $ORIGINAL_CPU_GOVERNOR..."
            sudo cpupower frequency-set -g "$ORIGINAL_CPU_GOVERNOR" >/dev/null 2>&1 || true
        else
            print_step "Restoring CPU governor to powersave..."
            sudo cpupower frequency-set -g powersave >/dev/null 2>&1 || true
        fi
    fi
}

# Create output directory
mkdir -p output

# Determine GA flag
if [ "$GA_ENABLED" = "ON" ]; then
    GA_FLAG="+ZUseGrowableArrayDiscoveredList"
else
    GA_FLAG="-ZUseGrowableArrayDiscoveredList"
fi

PROFILE_DATA="output/perf_${GA_ENABLED}_$(date +%Y%m%d_%H%M%S).data"
PROFILE_REPORT="${PROFILE_DATA%.data}.txt"
PROFILE_SCRIPT_OUTPUT="${PROFILE_DATA%.data}.log"

setup_cpu_performance
trap restore_cpu_governor EXIT

prepare_environment

print_header "PROFILING WITH PERF"
print_step "Running WeakRefMultiObjectBenchmark with perf record..."
echo "Profile data: $PROFILE_DATA"
echo "Report output: $PROFILE_REPORT"
echo ""

JAVA_OPTS="$COMMON_JVM_OPTS -XX:$GA_FLAG -XX:+PreserveFramePointer"
if [ -n "$LIBPERF_JVMTI" ]; then
    JAVA_OPTS="-agentpath:$LIBPERF_JVMTI $JAVA_OPTS"
fi

# Run with perf record
taskset -c "$CPU_CORES" nice -n -5 \
    sudo perf record \
        -F "$PERF_SAMPLING_FREQ" \
        -k 1 \
        -e "$PERF_EVENT" \
        -g \
        -o "$PROFILE_DATA" \
        $JAVA_BIN $JAVA_OPTS $BENCHMARK_CLASS > "$PROFILE_SCRIPT_OUTPUT" 2>&1

print_success "Profiling completed"

# Inject JIT symbols if libperf-jvmti was used
if [ -n "$LIBPERF_JVMTI" ]; then
    print_step "Injecting JIT symbols..."
    sudo perf inject -i "$PROFILE_DATA" --jit -o "${PROFILE_DATA}.jitted" >/dev/null 2>&1 && \
        sudo mv "${PROFILE_DATA}.jitted" "$PROFILE_DATA" && \
        print_success "JIT symbols injected" || \
        print_warning "Could not inject JIT symbols"
fi

# Generate perf report
print_step "Generating perf report..."
sudo perf report -i "$PROFILE_DATA" --stdio > "$PROFILE_REPORT" 2>&1

# Fix permissions
sudo chown "$USER:$USER" "$PROFILE_DATA" "$PROFILE_REPORT" 2>/dev/null || true

print_success "Report generated"

print_header "PERF PROFILING REPORT (GA $GA_ENABLED)"
echo ""
echo "=== TOP 30 FUNCTIONS BY CPU TIME ==="
echo ""
head -80 "$PROFILE_REPORT" | tail -30

echo ""
echo -e "${GREEN}Full report saved to: ${CYAN}$PROFILE_REPORT${NC}"
echo -e "${GREEN}Perf data saved to: ${CYAN}$PROFILE_DATA${NC}"
echo -e "${GREEN}Benchmark output saved to: ${CYAN}$PROFILE_SCRIPT_OUTPUT${NC}"
echo ""
echo -e "${YELLOW}To view the full report, run:${NC}"
echo "  perf report -i $PROFILE_DATA"
echo ""
echo -e "${YELLOW}To compare two profiles, run:${NC}"
echo "  perf diff profile_ON.data profile_OFF.data"
echo ""

