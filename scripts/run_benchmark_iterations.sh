#!/bin/bash

set -e

# Script to run weak reference benchmarks multiple times and aggregate results

# Default values
JAVA_BIN="./build/linux-x86_64-server-release/jdk/bin/java"
JCMD_BIN="./build/linux-x86_64-server-release/jdk/bin/jcmd"
COMMON_JVM_OPTS="${COMMON_JVM_OPTS:--Xms8g -Xmx8g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:ZCollectionIntervalMajor=0.5 -XX:+ZCollectionIntervalOnly -XX:NativeMemoryTracking=summary}"
SINGLE_JVM_OPTS="${SINGLE_JVM_OPTS:--Xms7g -Xmx7g -XX:+UseZGC -Xlog:gc+stats,gc+ref -XX:InitialTenuringThreshold=1 -XX:MaxTenuringThreshold=1 -XX:NativeMemoryTracking=summary}"
# Available benchmarks:
#   gc            -> WeakRefMultiObjectBenchmark     (many objects, each has its own WeakRef)
#   field         -> WeakFieldMultiObjectBenchmark   (many objects, each has its own @weak field)
#   single        -> WeakRefSingleObjectBenchmark    (many WeakRefs all pointing at one object)
#   field-single  -> WeakFieldSingleObjectBenchmark  (many @weak fields all pointing at one object)
BENCHMARK_NAME="${BENCHMARK_NAME:-gc}"
OUTER_ITERATIONS=100
CPU_CORES="${CPU_CORES:-0-11}"
MONITOR_CPU_CORES="${MONITOR_CPU_CORES:-12-19}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-0.0001}"  # 100us interval for monitoring
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
MONITOR_SCRIPT="./scripts/monitor_memory.sh"
RUN_ID=1  # Default ID for filenames

# Ensure the script itself runs on the monitor CPU cores so that the only
# thing bound to $CPU_CORES are the Java processes. If `taskset` is available
# re-exec the script under `taskset` once. Guard with SCRIPT_PINNED to avoid
# recursive re-exec.
if [ -z "$SCRIPT_PINNED" ]; then
    export SCRIPT_PINNED=1
    exec taskset -c "$MONITOR_CPU_CORES" env SCRIPT_PINNED=1 bash "$0" "$@"
else
    echo "Script is pinned to CPU cores $MONITOR_CPU_CORES for monitoring"
fi

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
while [ $# -gt 0 ]; do
    case $1 in
        --id)
            RUN_ID="$2"
            shift 2
            ;;
        --benchmark|-b)
            BENCHMARK_NAME="$2"
            shift 2
            ;;
        --cooldown|-c)
            COOLDOWN_SECONDS="$2"
            shift 2
            ;;
        *)
            if [ -z "$OUTER_ITERATIONS" ] || [ "$OUTER_ITERATIONS" = "100" ]; then
                OUTER_ITERATIONS=$1
                shift
            else
                shift
            fi
            ;;
    esac
done

# Resolve benchmark name to class file path
case "$BENCHMARK_NAME" in
    gc|weakref)
        BENCHMARK_CLASS="test/weakrefs/WeakRefMultiObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_CLASS="test/weakrefs/WeakFieldMultiObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_NAME="field"
        ;;
    single)
        BENCHMARK_CLASS="test/weakrefs/WeakRefSingleObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_CLASS="test/weakrefs/WeakFieldSingleObjectBenchmark.java"
        WEAK_FIELDS_BENCHMARK_NAME="field-single"
        ;;
    *)
        echo -e "${RED}Unknown benchmark name: $BENCHMARK_NAME${NC}"
        echo "Supported benchmarks: gc, weakref, single"
        exit 1
        ;;
esac

PRIMARY_BENCHMARK_CLASS="$BENCHMARK_CLASS"

print_header "WEAKREF GC BENCHMARK"
echo -e "${BOLD}Running:${NC} $OUTER_ITERATIONS runs × 3 iterations"
echo -e "${BOLD}Benchmark:${NC} $BENCHMARK_CLASS"
echo -e "${BOLD}Run ID:${NC} $RUN_ID"
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

        # Attempt to set the CPU scaling min/max to the platform base clock so
        # the CPUs run at the base frequency during the benchmark. Try reading
        # the canonical base_frequency file, fall back to cpuinfo_max_freq.
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

cleanup_old_results() {
    print_step "Cleaning up old CSV and log files for Run ID $RUN_ID..."
    
    mkdir -p output
    
    # Remove old benchmark output files only for this run ID
    rm -f output/run_*_run*_${RUN_ID}.log
    rm -f output/monitor_*_run*_${RUN_ID}.csv
    
    print_success "Old results cleaned up for Run ID $RUN_ID"
}

run_single() {
    local label=$1           # variant label
    local run=$2             # run number
    local total_runs=$3      # total number of runs

    # Create separate log and monitor files for each run with run number tag and execution ID
    local log_file="output/run_${BENCHMARK_NAME}_${label}_run${run}_${RUN_ID}.log"
    local monitor_log="output/monitor_${BENCHMARK_NAME}_${label}_run${run}_${RUN_ID}.csv"

    printf "${CYAN}▶${NC} Run %d/%d (GA %s) - Starting...${NC}\r" "$run" "$total_runs" "$label"
    echo ""
    echo "  Logging to: $log_file"
    echo "  Memory monitoring to: $monitor_log"
    
    if [ "$BENCHMARK_NAME" = "single" ]; then
        # Single-object benchmark triggers GC via System.gc(); uses its own opts (no ZGC timer, 7g heap)
        JAVA_OPTS="$SINGLE_JVM_OPTS"
    else
        JAVA_OPTS="$COMMON_JVM_OPTS"
    fi

    # Start Java process in background
    (
        echo ""
        echo "=== RUN $run/$total_runs (GA $label) ==="
        echo ""
        taskset -c "$CPU_CORES" nice -n -5 \
            $JAVA_BIN $JAVA_OPTS $BENCHMARK_CLASS 2>&1
    ) >> "$log_file" 2>&1 &
    
    local wrapper_pid=$!
    
    # Wait a moment for Java to actually start and get its PID
    sleep 1
    local java_pid=$(pgrep -P $wrapper_pid java | head -1)
    
    if [ -z "$java_pid" ]; then
        # Fallback: try to find the java process by other means
        java_pid=$(ps -o pid= --ppid $wrapper_pid 2>/dev/null | head -1 | tr -d ' ')
    fi
    
    # Start memory monitor on dedicated cores if we got the PID
    local monitor_pid=""
    if [ -n "$java_pid" ] && kill -0 $java_pid 2>/dev/null; then
        taskset -c "$MONITOR_CPU_CORES" nice -n 5 \
            $MONITOR_SCRIPT "$java_pid" "$monitor_log" "$MONITOR_INTERVAL" "$JCMD_BIN" "$log_file" &
        monitor_pid=$!
        printf "${CYAN}▶${NC} Run %d/%d (GA %s) - Memory monitor started (PID: %s -> %s on cores %s)\r" \
            "$run" "$total_runs" "$label" "$java_pid" "$monitor_pid" "$MONITOR_CPU_CORES"
        sleep 0.5
    fi
    
    # Monitor progress while Java is running
    local last_phase=""
    local last_iteration=""
    while kill -0 $wrapper_pid 2>/dev/null; do
        # Extract latest iteration and phase from log
        if [ -f "$log_file" ]; then
            last_iteration=$(grep -oP '=== Iteration \K\d+' "$log_file" | tail -1)
            # Capture phases like 'Phase 1' or 'Phase 4-1' and extract the numeric token
            last_phase=$(grep -oP 'Phase\s+\d+(?:-\d+)?' "$log_file" | tail -1 | awk '{print $2}')
        fi
        
        if [ -n "$last_iteration" ] && [ -n "$last_phase" ]; then
            printf "${CYAN}▶${NC} Run %d/%d (GA %s) - Iteration %s, Phase %s    \r" \
                "$run" "$total_runs" "$label" "$last_iteration" "$last_phase"
        elif [ -n "$last_iteration" ]; then
            printf "${CYAN}▶${NC} Run %d/%d (GA %s) - Iteration %s          \r" \
                "$run" "$total_runs" "$label" "$last_iteration"
        fi
        
        sleep 0.5
    done
    
    # Wait for process to complete
    wait $wrapper_pid
    local exit_code=$?
    
    # Monitor should stop automatically when Java exits, but ensure it's gone
    if [ -n "$monitor_pid" ]; then
        sleep 1
        kill $monitor_pid 2>/dev/null || true
    fi
    
    if [ $exit_code -eq 0 ]; then
        printf "${GREEN}✓${NC} Run %d/%d (GA %s) - Completed successfully!          \n" \
            "$run" "$total_runs" "$label"
        echo ""
    else
        printf "${RED}✗${NC} Run %d/%d (GA %s) - Failed with exit code %d\n" \
            "$run" "$total_runs" "$label" "$exit_code"
        echo ""
        return $exit_code
    fi

    return 0
}

setup_cpu_performance
trap restore_cpu_governor EXIT

cleanup_old_results

print_header "STARTING BENCHMARK SUITE"
print_step "Running all variant builds for each iteration"
echo ""

# Define the variants corresponding to builds created by scripts/build_exploded_images_variants.sh
variants=(
    "none"
    "all"
    "clear_path_only"
    "sep_only"
    "dyn_only"
    "clear_path_sep"
    "clear_path_dyn"
    "sep_dyn"
)

overall_status=0
for ((run=1; run<=OUTER_ITERATIONS; run++)); do
    for variant in "${variants[@]}"; do
        variant_build_dir="./build/${variant}-linux-x86_64-server-release"
        variant_java="$variant_build_dir/jdk/bin/java"
        variant_jcmd="$variant_build_dir/jdk/bin/jcmd"

        if [ ! -x "$variant_java" ]; then
            print_warning "Build for variant '$variant' not found at $variant_java; skipping"
            continue
        fi

        # Point global JAVA_BIN/JCMD_BIN to this variant for run_single internals
        JAVA_BIN="$variant_java"
        JCMD_BIN="$variant_jcmd"
        BENCHMARK_CLASS="$PRIMARY_BENCHMARK_CLASS"

        print_header "Run $run/$OUTER_ITERATIONS - Variant $variant"
        prepare_environment
        run_single "$variant" "$run" "$OUTER_ITERATIONS"
        if [ $? -ne 0 ]; then
            overall_status=1
            break 2
        fi
    done

    # Weak-fields configuration: always run with the "none" build variant.
    if [ -n "$WEAK_FIELDS_BENCHMARK_CLASS" ]; then
        variant="none"
        variant_build_dir="./build/${variant}-linux-x86_64-server-release"
        variant_java="$variant_build_dir/jdk/bin/java"
        variant_jcmd="$variant_build_dir/jdk/bin/jcmd"

        if [ ! -x "$variant_java" ]; then
            print_warning "Build for weak_fields configuration not found at $variant_java; skipping"
            continue
        fi

        JAVA_BIN="$variant_java"
        JCMD_BIN="$variant_jcmd"
        BENCHMARK_CLASS="$WEAK_FIELDS_BENCHMARK_CLASS"

        print_header "Run $run/$OUTER_ITERATIONS - Variant weak_fields (build none)"
        prepare_environment
        run_single "weak_fields" "$run" "$OUTER_ITERATIONS"
        if [ $? -ne 0 ]; then
            overall_status=1
            break
        fi

        BENCHMARK_CLASS="$PRIMARY_BENCHMARK_CLASS"
    fi
done

if [ $overall_status -ne 0 ]; then
    print_header "BENCHMARK FAILED"
    echo -e "${RED}One or more runs failed. Check the log files for details.${NC}"
    exit 1
fi

print_header "BENCHMARK COMPLETE"
echo -e "${BOLD}All benchmark runs completed successfully!${NC}"
echo ""
echo -e "${GREEN}Output Summary:${NC}"
echo "  • Benchmark logs:     output/run_${BENCHMARK_NAME}_<variant>_run*_${RUN_ID}.log"
echo "  • Memory monitoring:  output/monitor_${BENCHMARK_NAME}_<variant>_run*_${RUN_ID}.csv"
if [ -n "$WEAK_FIELDS_BENCHMARK_NAME" ]; then
    echo "  • Weak-fields config: output/run_${WEAK_FIELDS_BENCHMARK_NAME}_weak_fields_run*_${RUN_ID}.log"
    echo "                        output/monitor_${WEAK_FIELDS_BENCHMARK_NAME}_weak_fields_run*_${RUN_ID}.csv"
fi
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "  To analyze and compare results, run:"
echo -e "  ${YELLOW}python3 scripts/parse_gc_stats.py${NC}"
echo ""
