#!/bin/bash

# Benchmark script for Custom JDK with Poll mode (Scan-based cleanup, no ReferenceQueue)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_JDK="${SCRIPT_DIR}/build/linux-x86_64-server-release/jdk"
CAFFEINE_DIR="${SCRIPT_DIR}/caffeine"
RESULTS_DIR="${SCRIPT_DIR}/benchmark_results"

# Benchmark environment settings
CPU_CORES="${CPU_CORES:-0-11}"          # CPU cores to pin to (override with CPU_CORES env var)
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"  # Seconds to wait between benchmarks

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

print_header() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Function to prepare environment before each benchmark
prepare_environment() {
    print_step "Preparing environment..."
    
    # Drop filesystem caches (requires sudo, skip if not available)
    if command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
        echo "  Dropping filesystem caches..."
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
    else
        print_warning "  Skipping cache drop (no sudo access)"
    fi
    
    # Stop Gradle daemon to ensure fresh JVM for each benchmark
    echo "  Stopping Gradle daemon..."
    ./gradlew --stop 2>/dev/null || true
    
    # Wait for system to settle
    echo "  Cooldown period (${COOLDOWN_SECONDS}s)..."
    sleep "$COOLDOWN_SECONDS"
    
    # Force garbage collection in any remaining Java processes
    # (JMH will start fresh JVMs anyway, but this helps clean up Gradle)
    
    print_success "Environment prepared"
}

# Function to set CPU governor to performance (requires sudo)
setup_cpu_performance() {
    if command -v cpupower &> /dev/null && sudo -n true 2>/dev/null; then
        print_step "Setting CPU governor to performance mode..."
        sudo cpupower frequency-set -g performance 2>/dev/null || print_warning "Could not set CPU governor"
        
        # Try to pin frequency to the CPU base clock
        base_freq=""
        base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null || true)
        if [ -z "$base_freq" ]; then
            base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || true)
        fi
        
        if [ -n "$base_freq" ]; then
            print_step "Pinning CPU frequencies to base: $base_freq KHz"
            for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
                if [ -d "$cpu_dir" ]; then
                    # Set max first, then min to avoid conflicts
                    echo "$base_freq" | sudo tee "$cpu_dir/scaling_max_freq" > /dev/null 2>&1
                    echo "$base_freq" | sudo tee "$cpu_dir/scaling_min_freq" > /dev/null 2>&1
                fi
            done
            # Verify the settings
            actual_min=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null)
            actual_max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
            if [ "$actual_min" = "$base_freq" ] && [ "$actual_max" = "$base_freq" ]; then
                print_success "CPU frequencies pinned to $base_freq KHz"
            else
                print_warning "Frequency pinning partial: min=$actual_min, max=$actual_max (target: $base_freq)"
            fi
        else
            print_warning "Could not determine base CPU frequency; skipping frequency pinning"
        fi
    fi
}

# Function to restore CPU governor
restore_cpu_governor() {
    if command -v cpupower &> /dev/null && sudo -n true 2>/dev/null; then
        print_step "Restoring CPU governor to powersave..."
        sudo cpupower frequency-set -g powersave 2>/dev/null || true
    fi
}

# Create results directory
mkdir -p "$RESULTS_DIR"

# Check if custom JDK exists
if [ ! -d "$CUSTOM_JDK" ]; then
    echo -e "${RED}Error: Custom JDK build not found at $CUSTOM_JDK${NC}"
    echo "Please build the JDK first with: bash configure && make images"
    exit 1
fi

# Check if Caffeine directory exists
if [ ! -d "$CAFFEINE_DIR" ]; then
    echo -e "${RED}Error: Caffeine directory not found at $CAFFEINE_DIR${NC}"
    exit 1
fi

cd "$CAFFEINE_DIR"

# Function to run benchmark
run_benchmark() {
    local jdk_path="$1"
    local jdk_name="$2"
    local mode="$3"
    local benchmark_pattern="$4"
    local output_file="$5"
    local growable_array_option="$6"  # "enabled" or "disabled"
    
    # Prepare environment before each run
    prepare_environment
    
    export JAVA_HOME="$jdk_path"
    export PATH="$JAVA_HOME/bin:$PATH"
    
    local growable_array_flag=""
    local growable_array_display=""
    if [ "$growable_array_option" == "enabled" ]; then
        growable_array_flag="-XX:+ZUseGrowableArrayDiscoveredList"
        growable_array_display="GrowableArray=ON"
    elif [ "$growable_array_option" == "disabled" ]; then
        growable_array_flag="-XX:-ZUseGrowableArrayDiscoveredList"
        growable_array_display="GrowableArray=OFF"
    fi
    
    print_step "Running: $jdk_name + $mode mode + $growable_array_display + $benchmark_pattern"
    echo "  JDK: $jdk_path"
    echo "  Mode: -Dcaffeine.referenceCleanup=$mode"
    echo "  GrowableArray: $growable_array_flag"
    echo "  Benchmark: $benchmark_pattern"
    echo "  CPU cores: $CPU_CORES"
    echo ""
    
    # Run with taskset for CPU pinning and nice for priority
    taskset -c "$CPU_CORES" nice -n -5 \
        ./gradlew jmh -PjavaVersion=27 \
            "-Porg.gradle.java.installations.paths=$jdk_path" \
            -PincludePattern="$benchmark_pattern" \
            "-PjvmArgs=-XX:+UseZGC,-XX:+UnlockDiagnosticVMOptions,$growable_array_flag,-Dcaffeine.referenceCleanup=$mode" \
            --rerun -q 2>&1 | tee "$output_file"
    
    print_success "Completed: $jdk_name + $mode mode + $growable_array_display + $benchmark_pattern"
    echo ""
}

# Function to extract all main benchmark results (not sub-benchmarks)
extract_main_results() {
    local file="$1"
    grep -E "^(GetPutWeakRefBenchmark|ComputeWeakRefBenchmark|PutRemoveWeakRefBenchmark|EvictionWeakRefBenchmark|TimerWheelBenchmark)\." "$file" || true
}

print_header "CAFFEINE BENCHMARK SUITE - POLL MODE ONLY"
echo "Testing Custom JDK with Poll mode (Scan-based cleanup, no ReferenceQueue)"
echo ""
echo "Benchmarks to run:"
echo "  • GetPutWeakRefBenchmark - Basic get/put operations with weak references"
echo "  • ComputeWeakRefBenchmark - computeIfAbsent with weak references"
echo "  • PutRemoveWeakRefBenchmark - High churn put/remove operations with weak references"
echo "  • EvictionWeakRefBenchmark - 100% eviction rate with weak references"
echo "  • TimerWheelBenchmark - Time-based expiration"
echo ""
echo "Custom JDK:   $CUSTOM_JDK"
echo ""
echo -e "${BOLD}Environment Settings:${NC}"
echo "  CPU cores:    $CPU_CORES"
echo "  Cooldown:     ${COOLDOWN_SECONDS}s between runs"
echo "  CPU pinning:  taskset -c $CPU_CORES"
echo "  Priority:     nice -n -5"
echo ""

# Try to set CPU governor to performance mode
setup_cpu_performance

# Trap to restore CPU governor on exit
trap restore_cpu_governor EXIT

# List of benchmarks to run
BENCHMARKS=(
    "GetPutWeakRefBenchmark"
    "ComputeWeakRefBenchmark"
    "PutRemoveWeakRefBenchmark"
    "EvictionWeakRefBenchmark"
    "TimerWheelBenchmark"
)

# Run all benchmarks in poll mode with both GrowableArray settings
BENCHMARK_PATTERN=$(IFS='|'; echo "${BENCHMARKS[*]}")

print_header "1/2: Custom JDK + Poll Mode + GrowableArray ON (All Benchmarks)"
run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_poll_growable_on.txt" "enabled"

print_header "2/2: Custom JDK + Poll Mode + GrowableArray OFF (All Benchmarks)"
run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_poll_growable_off.txt" "disabled"

# Generate summary report
print_header "BENCHMARK RESULTS"

echo -e "${BOLD}Caffeine Cache Performance - Poll Mode (ops/s - higher is better)${NC}"
echo ""

if [ -f "${RESULTS_DIR}/custom_poll_growable_on.txt" ]; then
    echo -e "${CYAN}Custom JDK + Poll Mode + GrowableArray ON${NC}"
    echo "────────────────────────────────────────────────────────────────────────"
    extract_main_results "${RESULTS_DIR}/custom_poll_growable_on.txt" | while read line; do
        bench=$(echo "$line" | awk '{print $1}')
        cache=$(echo "$line" | awk '{print $2}')
        score=$(echo "$line" | awk '{printf "%.2fM", $5/1000000}')
        error=$(echo "$line" | awk '{printf "±%.2fM", $7/1000000}')
        printf "  %-50s %-15s %12s %12s ops/s\n" "$bench" "$cache" "$score" "$error"
    done
    echo ""
fi

if [ -f "${RESULTS_DIR}/custom_poll_growable_off.txt" ]; then
    echo -e "${CYAN}Custom JDK + Poll Mode + GrowableArray OFF${NC}"
    echo "────────────────────────────────────────────────────────────────────────"
    extract_main_results "${RESULTS_DIR}/custom_poll_growable_off.txt" | while read line; do
        bench=$(echo "$line" | awk '{print $1}')
        cache=$(echo "$line" | awk '{print $2}')
        score=$(echo "$line" | awk '{printf "%.2fM", $5/1000000}')
        error=$(echo "$line" | awk '{printf "±%.2fM", $7/1000000}')
        printf "  %-50s %-15s %12s %12s ops/s\n" "$bench" "$cache" "$score" "$error"
    done
    echo ""
fi

print_header "BENCHMARK COMPLETE"
echo "Raw results saved to:"
echo "  ${RESULTS_DIR}/custom_poll_growable_on.txt"
echo "  ${RESULTS_DIR}/custom_poll_growable_off.txt"
echo ""
echo "Tested configurations:"
echo "  • Poll mode + GrowableArray ON"
echo "  • Poll mode + GrowableArray OFF"
echo ""
