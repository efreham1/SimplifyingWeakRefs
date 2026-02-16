#!/bin/bash

set -e

# Script to run WeakRefGcBenchmark multiple times and aggregate results

# Default values
JAVA_BIN="./build/linux-x86_64-server-release/jdk/bin/java"
COMMON_JVM_OPTS="${COMMON_JVM_OPTS:--Xms1g -Xmx8g -XX:+UseZGC -Xlog:gc+stats -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:+UnlockDiagnosticVMOptions}"
BENCHMARK_CLASS="test/weakrefs/WeakRefGcBenchmark.java"
OUTER_ITERATIONS=5
INNER_ITERATIONS=10
CPU_CORES="${CPU_CORES:-0-11}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"

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
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

print_step() { echo -e "${YELLOW}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Parse command line arguments
if [ $# -ge 1 ]; then
    OUTER_ITERATIONS=$1
fi
if [ $# -ge 2 ]; then
    INNER_ITERATIONS=$2
fi

print_header "WEAKREF GC BENCHMARK"
echo -e "${BOLD}Running:${NC} $OUTER_ITERATIONS runs × $INNER_ITERATIONS iterations"
echo -e "${BOLD}CPU cores:${NC} $CPU_CORES"
echo -e "${BOLD}Cooldown:${NC} ${COOLDOWN_SECONDS}s between GA configs"
echo -e "${BOLD}JVM opts:${NC} $COMMON_JVM_OPTS"
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

run_suite() {
    local growable_flag=$1   # "+ZUseGrowableArrayDiscoveredList" or "-ZUseGrowableArrayDiscoveredList"
    local label=$2           # display label

    # Arrays to store per-run metrics extracted from GC stats
    enqueue_avgs=()
    process_avgs=()
    mark_avgs=()
    major_avgs=()
    minor_avgs=()
    oldgen_avgs=()

    print_header "GA $label"
    print_step "Running $OUTER_ITERATIONS runs × $INNER_ITERATIONS iterations"

    for ((run=1; run<=OUTER_ITERATIONS; run++)); do
        echo ""
        echo "=== RUN $run/$OUTER_ITERATIONS (GA $label) ==="

        JAVA_OPTS="$COMMON_JVM_OPTS -XX:$growable_flag"

        output=$(taskset -c "$CPU_CORES" nice -n -5 \
            $JAVA_BIN $JAVA_OPTS $BENCHMARK_CLASS 2000000 256 4096 250 1024 $INNER_ITERATIONS)

        echo "$output"

        enqueue=$(echo "$output" | awk '/Concurrent References Enqueue/ {for (i=NF; i>=1; i--) if ($i == "/") {print $(i-1); exit}}')
        process=$(echo "$output" | awk '/Concurrent References Process/ {for (i=NF; i>=1; i--) if ($i == "/") {print $(i-1); exit}}')
        mark=$(echo "$output" | awk '/Old Phase: Concurrent Mark/ {for (i=NF; i>=1; i--) if ($i == "/") {print $(i-1); exit}}')
        major=$(echo "$output" | awk '/Major Collection: Major Collection/ {for (i=NF; i>=1; i--) if ($i == "/") {print $(i-1); exit}}')
        minor=$(echo "$output" | awk '/Minor Collection: Minor Collection/ {for (i=NF; i>=1; i--) if ($i == "/") {print $(i-1); exit}}')
        oldgen=$(echo "$output" | awk '/Old Generation: Old Generation/ {for (i=NF; i>=1; i--) if ($i == "/") {print $(i-1); exit}}')

        if [ -n "$enqueue" ]; then
            enqueue_avgs+=("$enqueue")
            echo "Run $run enqueue avg: $enqueue ms"
        else
            echo "WARNING: Could not extract enqueue avg from run $run"
        fi

        if [ -n "$process" ]; then
            process_avgs+=("$process")
            echo "Run $run process avg: $process ms"
        else
            echo "WARNING: Could not extract process avg from run $run"
        fi

        if [ -n "$mark" ]; then
            mark_avgs+=("$mark")
            echo "Run $run mark avg: $mark ms"
        else
            echo "WARNING: Could not extract mark avg from run $run"
        fi

        if [ -n "$major" ]; then
            major_avgs+=("$major")
            echo "Run $run major avg: $major ms"
        else
            echo "WARNING: Could not extract major avg from run $run"
        fi

        if [ -n "$minor" ]; then
            minor_avgs+=("$minor")
            echo "Run $run minor avg: $minor ms"
        else
            echo "WARNING: Could not extract minor avg from run $run"
        fi

        if [ -n "$oldgen" ]; then
            oldgen_avgs+=("$oldgen")
            echo "Run $run oldgen avg: $oldgen ms"
        else
            echo "WARNING: Could not extract oldgen avg from run $run"
        fi
    done

    print_header "FINAL RESULTS (GA $label)"

    compute_stats enqueue_avgs "enqueue"
    enqueue_ok=$?

    compute_stats process_avgs "process"
    process_ok=$?

    compute_stats mark_avgs "mark"
    mark_ok=$?

    compute_stats major_avgs "major"
    major_ok=$?

    compute_stats minor_avgs "minor"
    minor_ok=$?

    compute_stats oldgen_avgs "oldgen"
    oldgen_ok=$?

    local enqueue_mean="$(calc_mean enqueue_avgs)"
    local process_mean="$(calc_mean process_avgs)"
    local mark_mean="$(calc_mean mark_avgs)"
    local major_mean="$(calc_mean major_avgs)"
    local minor_mean="$(calc_mean minor_avgs)"
    local oldgen_mean="$(calc_mean oldgen_avgs)"

    if [ "$label" = "ON" ]; then
        GA_ON_ENQUEUE_MEAN="$enqueue_mean"
        GA_ON_PROCESS_MEAN="$process_mean"
        GA_ON_MARK_MEAN="$mark_mean"
        GA_ON_MAJOR_MEAN="$major_mean"
        GA_ON_MINOR_MEAN="$minor_mean"
        GA_ON_OLDGEN_MEAN="$oldgen_mean"
    else
        GA_OFF_ENQUEUE_MEAN="$enqueue_mean"
        GA_OFF_PROCESS_MEAN="$process_mean"
        GA_OFF_MARK_MEAN="$mark_mean"
        GA_OFF_MAJOR_MEAN="$major_mean"
        GA_OFF_MINOR_MEAN="$minor_mean"
        GA_OFF_OLDGEN_MEAN="$oldgen_mean"
    fi

    if [ $enqueue_ok -ne 0 ] || [ $process_ok -ne 0 ] || [ $mark_ok -ne 0 ] || [ $major_ok -ne 0 ] || [ $minor_ok -ne 0 ] || [ $oldgen_ok -ne 0 ]; then
        return 1
    fi

    return 0
}

# Compute stats helper
compute_stats() {
    local -n arr=$1
    local label=$2

    if [ ${#arr[@]} -eq 0 ]; then
        echo "ERROR: No valid $label results collected"
        return 1
    fi

    local total=0
    local count=0

    echo "Individual run $label averages:"
    for val in "${arr[@]}"; do
        count=$((count + 1))
        echo "  Run $count: $val ms"
        total=$(echo "$total + $val" | bc)
    done

    local overall_avg=$(echo "scale=3; $total / ${#arr[@]}" | bc)

    local sum_sq_diff=0
    for val in "${arr[@]}"; do
        diff=$(echo "$val - $overall_avg" | bc)
        sq_diff=$(echo "$diff * $diff" | bc)
        sum_sq_diff=$(echo "$sum_sq_diff + $sq_diff" | bc)
    done
    local variance=$(echo "scale=3; $sum_sq_diff / ${#arr[@]}" | bc)
    local stddev=$(echo "scale=3; sqrt($variance)" | bc -l)

    echo ""
    echo "Overall average $label: $overall_avg ms"
    echo "Standard deviation: $stddev ms"
    echo "Min: $(printf '%s\n' "${arr[@]}" | sort -n | head -1) ms"
    echo "Max: $(printf '%s\n' "${arr[@]}" | sort -n | tail -1) ms"
    echo ""
    return 0
}

calc_mean() {
    local -n arr=$1
    if [ ${#arr[@]} -eq 0 ]; then
        echo ""
        return
    fi
    local total=0
    for val in "${arr[@]}"; do
        total=$(echo "$total + $val" | bc)
    done
    echo "scale=3; $total / ${#arr[@]}" | bc
}

setup_cpu_performance
trap restore_cpu_governor EXIT

prepare_environment

run_suite "+ZUseGrowableArrayDiscoveredList" "ON"
ga_on_status=$?

prepare_environment

run_suite "-ZUseGrowableArrayDiscoveredList" "OFF"
ga_off_status=$?

if [ $ga_on_status -ne 0 ] || [ $ga_off_status -ne 0 ]; then
    exit 1
fi

print_header "BENCHMARK COMPLETE"
print_success "GA ON and GA OFF suites finished"

echo ""
echo -e "${BOLD}Comparison (means, ms):${NC}"
printf "  Enqueue: ON=%s   OFF=%s\n" "${GA_ON_ENQUEUE_MEAN:-n/a}" "${GA_OFF_ENQUEUE_MEAN:-n/a}"
printf "  Process: ON=%s   OFF=%s\n" "${GA_ON_PROCESS_MEAN:-n/a}" "${GA_OFF_PROCESS_MEAN:-n/a}"
printf "  Mark:    ON=%s   OFF=%s\n" "${GA_ON_MARK_MEAN:-n/a}" "${GA_OFF_MARK_MEAN:-n/a}"
printf "  Major:   ON=%s   OFF=%s\n" "${GA_ON_MAJOR_MEAN:-n/a}" "${GA_OFF_MAJOR_MEAN:-n/a}"
printf "  Minor:   ON=%s   OFF=%s\n" "${GA_ON_MINOR_MEAN:-n/a}" "${GA_OFF_MINOR_MEAN:-n/a}"
printf "  OldGen:  ON=%s   OFF=%s\n" "${GA_ON_OLDGEN_MEAN:-n/a}" "${GA_OFF_OLDGEN_MEAN:-n/a}"
