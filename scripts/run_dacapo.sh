#!/bin/bash

set -e

# Script to run DaCapo jython benchmark and compare performance with Growable Array (GA) on vs off

# Default values
JAVA_BIN="${JAVA_BIN:-./build/linux-x86_64-server-release/jdk/bin/java}"
DACAPO_JAR="${DACAPO_JAR:-../dacapo-23.11-MR2-chopin/dacapo-23.11-MR2-chopin.jar}"
BENCHMARK="jython"
ITERATIONS="${ITERATIONS:-10}"
SIZE="${SIZE:-default}"
WARMUP="${WARMUP:-120}"
BASE_JVM_OPTS="${BASE_JVM_OPTS:--Xms4g -Xmx4g -XX:+UseZGC -Xlog:gc+ref -XX:+UnlockDiagnosticVMOptions}"
GA_ON_OPTS="${GA_ON_OPTS:--XX:+ZUseGrowableArrayDiscoveredList}"
GA_OFF_OPTS="${GA_OFF_OPTS:--XX:-ZUseGrowableArrayDiscoveredList}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
CPU_CORES="${CPU_CORES:-0-11}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-5}"
RUN_COUNT="${RUN_COUNT:-1}"

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
print_error() { echo -e "${RED}✗ $1${NC}"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run DaCapo jython benchmark with Growable Array (GA) on and GA off, comparing performance.

OPTIONS:
    -i, --iterations NUM        Number of iterations per run (default: 10)
    -w, --warmup NUM            Number of warmup iterations (default: 3)
    -s, --size SIZE            Benchmark size: small, default, large (default: default)
    -r, --runs NUM             Number of benchmark runs (default: 1)
    -o, --output DIR           Output directory for results (default: ./output)
    
    -j, --java PATH            Path to Java binary (default: ./build/linux-x86_64-server-release/jdk/bin/java)
    -d, --dacapo PATH          Path to DaCapo jar (default: ./dacapo-23.11-MR2-chopin.jar)
    
    --base-jvm-opts "OPTS"     Base JVM options (default: "-Xms4g -Xmx4g -XX:+UseZGC")
    --ga-on "OPTS"             Growable Array on options (default: "-XX:+UseGrowableArray")
    --ga-off "OPTS"            Growable Array off options (default: "-XX:-UseGrowableArray")
    
    --cpu-cores CORES          CPU cores to pin (default: 0-11)
    --cooldown SEC             Cooldown time in seconds (default: 5)
    
    -h, --help                 Show this help message

EXAMPLES:
    # Run jython benchmark 3 times with GA on and off
    $0 -r 3

    # Run with 20 iterations each
    $0 -i 20 -r 3

    # Run with custom base JVM options
    $0 --base-jvm-opts "-Xms8g -Xmx8g -XX:+UseZGC -Xlog:gc"

    # Run with custom GA options
    $0 --ga-on "-XX:+UseGenerationalCards -XX:CardSize=512" \\
        --ga-off "-XX:-UseGenerationalCards"

EOF
    exit 0
}

list_benchmarks() {
    print_header "Warning: This script runs only jython"
    echo "To run other DaCapo benchmarks, modify the script or use a different runner."
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        -w|--warmup)
            WARMUP="$2"
            shift 2
            ;;
        -s|--size)
            SIZE="$2"
            shift 2
            ;;
        -r|--runs)
            RUN_COUNT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -j|--java)
            JAVA_BIN="$2"
            shift 2
            ;;
        -d|--dacapo)
            DACAPO_JAR="$2"
            shift 2
            ;;
        --base-jvm-opts)
            BASE_JVM_OPTS="$2"
            shift 2
            ;;
        --ga-on)
            GA_ON_OPTS="$2"
            shift 2
            ;;
        --ga-off)
            GA_OFF_OPTS="$2"
            shift 2
            ;;
        --cpu-cores)
            CPU_CORES="$2"
            shift 2
            ;;
        --cooldown)
            COOLDOWN_SECONDS="$2"
            shift 2
            ;;
        --list)
            list_benchmarks
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validation
if [ ! -f "$JAVA_BIN" ]; then
    print_error "Java binary not found at: $JAVA_BIN"
    echo "Please build the JDK first using 'make' or set JAVA_BIN environment variable"
    exit 1
fi

if [ ! -f "$DACAPO_JAR" ]; then
    print_error "DaCapo jar not found at: $DACAPO_JAR"
    echo "Please download DaCapo from https://github.com/dacapobench/dacapobench"
    echo "and place it in the current directory, or set DACAPO_JAR environment variable"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

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

# Trap to ensure cleanup happens
trap restore_cpu_governor EXIT

# Print configuration
print_header "DaCapo jython: Growable Array (GA) Performance Comparison"
echo -e "${BOLD}Benchmark:${NC}     jython"
echo -e "${BOLD}Runs per mode:${NC}  $RUN_COUNT"
echo -e "${BOLD}Iterations:${NC}    $ITERATIONS (warmup: $WARMUP)"
echo -e "${BOLD}Size:${NC}          $SIZE"
echo -e "${BOLD}Java binary:${NC}   $JAVA_BIN"
echo -e "${BOLD}DaCapo jar:${NC}    $DACAPO_JAR"
echo -e "${BOLD}Base JVM opts:${NC} $BASE_JVM_OPTS"
echo -e "${BOLD}GA ON opts:${NC}    $GA_ON_OPTS"
echo -e "${BOLD}GA OFF opts:${NC}   $GA_OFF_OPTS"
echo -e "${BOLD}CPU cores:${NC}     $CPU_CORES"
echo -e "${BOLD}Output dir:${NC}    $OUTPUT_DIR"
echo ""

# Verify Java version
print_step "Checking Java version..."
$JAVA_BIN -version
echo ""

# Setup CPU performance
setup_cpu_performance

# Prepare environment
prepare_environment

# Generate timestamp for output file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR_TIMESTAMPED="${OUTPUT_DIR}/jython_comparison_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR_TIMESTAMPED"

# Arrays to store results
declare -a GA_ON_TIMES
declare -a GA_OFF_TIMES

run_benchmark() {
    local ga_mode="$1"
    local ga_opts="$2"
    local run_num="$3"
    
    local jvm_opts="$BASE_JVM_OPTS $ga_opts"
    local output_file="${OUTPUT_DIR_TIMESTAMPED}/jython_${ga_mode}_run${run_num}.log"
    
    # Build the command
    local cmd="taskset -c $CPU_CORES $JAVA_BIN $jvm_opts -jar $DACAPO_JAR"
    
    # Add DaCapo options
    cmd="$cmd -n $ITERATIONS"
    
    if [ "$WARMUP" != "0" ]; then
        cmd="$cmd -w $WARMUP"
    fi
    
    if [ "$SIZE" != "default" ]; then
        cmd="$cmd -s $SIZE"
    fi
    
    # Add benchmark name
    cmd="$cmd jython"
    
    echo -e "${CYAN}Command:${NC} $cmd"
    
    # Run the benchmark
    if $cmd 2>&1 | tee "$output_file"; then
        # Try to extract execution time
        if grep -q "PASSED" "$output_file"; then
            print_success "Run completed"
        fi
    else
        print_error "Run failed!"
        return 1
    fi
    
    return 0
}

print_header "Running DaCapo jython Benchmark with Growable Array ON and OFF"

# Run with GA ON
print_header "Growable Array ON Configuration ($RUN_COUNT runs)"
echo -e "${BOLD}JVM options:${NC} $BASE_JVM_OPTS $GA_ON_OPTS"
echo ""

for ((i=1; i<=RUN_COUNT; i++)); do
    print_step "Growable Array ON - Run $i of $RUN_COUNT"
    prepare_environment
    
    if ! run_benchmark "ga_on" "$GA_ON_OPTS" "$i"; then
        print_error "Growable Array ON run $i failed"
        exit 1
    fi
    
    echo ""
done

# Run with GA OFF
print_header "Growable Array OFF Configuration ($RUN_COUNT runs)"
echo -e "${BOLD}JVM options:${NC} $BASE_JVM_OPTS $GA_OFF_OPTS"
echo ""

for ((i=1; i<=RUN_COUNT; i++)); do
    print_step "Growable Array OFF - Run $i of $RUN_COUNT"
    prepare_environment
    
    if ! run_benchmark "ga_off" "$GA_OFF_OPTS" "$i"; then
        print_error "Growable Array OFF run $i failed"
        exit 1
    fi
    
    echo ""
done

print_header "Results Summary"
echo -e "${BOLD}All benchmark logs saved to:${NC} $OUTPUT_DIR_TIMESTAMPED"
echo ""
echo -e "${BOLD}Growable Array ON runs:${NC}"
for ((i=1; i<=RUN_COUNT; i++)); do
    file="${OUTPUT_DIR_TIMESTAMPED}/jython_ga_on_run${i}.log"
    if [ -f "$file" ]; then
        echo "  Run $i: $file"
    fi
done

echo ""
echo -e "${BOLD}Growable Array OFF runs:${NC}"
for ((i=1; i<=RUN_COUNT; i++)); do
    file="${OUTPUT_DIR_TIMESTAMPED}/jython_ga_off_run${i}.log"
    if [ -f "$file" ]; then
        echo "  Run $i: $file"
    fi
done

print_success "All benchmarks completed successfully!"
echo ""
echo -e "${CYAN}To compare results, analyze the log files in $OUTPUT_DIR_TIMESTAMPED${NC}"
