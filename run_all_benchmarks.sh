#!/bin/bash

# Benchmark script comparing two configurations:
# 1. Custom JDK + Queue mode (ReferenceQueue-based cleanup)
# 2. Custom JDK + Poll mode (Scan-based cleanup, no ReferenceQueue)
#
# Usage:
#   ./run_all_benchmarks.sh           - Run benchmarks
#   ./run_all_benchmarks.sh --results - Show previous results only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_JDK="${SCRIPT_DIR}/build/linux-x86_64-server-release/jdk"
CAFFEINE_DIR="${SCRIPT_DIR}/caffeine"
RESULTS_DIR="${SCRIPT_DIR}/benchmark_results"
AGENT_DIR="${SCRIPT_DIR}/WeakRefAgent"
AGENT_JAR="${AGENT_DIR}/weakref-agent.jar"
CONFIG_FILE="${SCRIPT_DIR}/benchmark_config.sh"

# Load configuration file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${YELLOW}Warning: Configuration file not found at $CONFIG_FILE${NC}"
    echo "Using default configuration (all benchmarks enabled)"
    RUN_QUEUE_GROWABLE_ON=true
    RUN_QUEUE_GROWABLE_ON_AGENT=true
    RUN_QUEUE_GROWABLE_OFF=true
    RUN_QUEUE_GROWABLE_OFF_AGENT=true
    RUN_POLL_GROWABLE_ON=true
    RUN_POLL_GROWABLE_ON_AGENT=true
    RUN_POLL_GROWABLE_OFF=true
    RUN_POLL_GROWABLE_OFF_AGENT=true
fi

# Check if we should just show results
SHOW_RESULTS_ONLY=false
if [ "$1" == "--results" ] || [ "$1" == "-r" ]; then
    SHOW_RESULTS_ONLY=true
fi

# Benchmark environment settings
CPU_CORES="${CPU_CORES:-0-11}"          # CPU cores to pin to (override with CPU_CORES env var)
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"  # Seconds to wait between benchmarks
# Comma-separated JVM options passed via -PjvmArgs; override with COMMON_JVM_OPTS env var
COMMON_JVM_OPTS="${COMMON_JVM_OPTS:--XX:+UseZGC,-XX:InitialTenuringThreshold=1,-XX:MaxTenuringThreshold=1,-XX:+UnlockDiagnosticVMOptions}"

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
    
    print_success "Environment prepared"
}

# Variable to store original CPU governor and freq
ORIGINAL_CPU_GOVERNOR=""
ORIGINAL_MIN_FREQ=""
ORIGINAL_MAX_FREQ=""

# Function to set CPU governor to performance (requires sudo)
setup_cpu_performance() {
    if command -v cpupower &> /dev/null && sudo -n true 2>/dev/null; then
        # Save current governor
        ORIGINAL_CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")

        # Save current min/max frequencies (cpu0 as representative)
        ORIGINAL_MIN_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "")
        ORIGINAL_MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "")

        if [ -n "$ORIGINAL_CPU_GOVERNOR" ]; then
            print_step "Setting CPU governor to performance mode (current: $ORIGINAL_CPU_GOVERNOR)..."
            sudo cpupower frequency-set -g performance 2>/dev/null || print_warning "Could not set CPU governor"
        else
            print_step "Setting CPU governor to performance mode..."
            sudo cpupower frequency-set -g performance 2>/dev/null || print_warning "Could not set CPU governor"
        fi

        # Try to pin frequency to the CPU base clock
        base_freq=""
        base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null || true)
        if [ -z "$base_freq" ]; then
            base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || true)
        fi
        if [ -z "$base_freq" ]; then
            base_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || true)
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
        # Restore original min/max freqs if we saved them
        if [ -n "$ORIGINAL_MIN_FREQ" ] && [ -n "$ORIGINAL_MAX_FREQ" ]; then
            print_step "Restoring CPU min/max frequencies to ${ORIGINAL_MIN_FREQ}/${ORIGINAL_MAX_FREQ}..."
            for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
                if [ -d "$cpu_dir" ]; then
                    echo "$ORIGINAL_MIN_FREQ" | sudo tee "$cpu_dir/scaling_min_freq" > /dev/null 2>&1 || true
                    echo "$ORIGINAL_MAX_FREQ" | sudo tee "$cpu_dir/scaling_max_freq" > /dev/null 2>&1 || true
                fi
            done
        fi

        if [ -n "$ORIGINAL_CPU_GOVERNOR" ]; then
            print_step "Restoring CPU governor to $ORIGINAL_CPU_GOVERNOR..."
            sudo cpupower frequency-set -g "$ORIGINAL_CPU_GOVERNOR" 2>/dev/null || true
        else
            print_step "Restoring CPU governor to powersave..."
            sudo cpupower frequency-set -g powersave 2>/dev/null || true
        fi
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

# Build WeakRefPressureAgent if needed
build_agent() {
    if [ ! -f "$AGENT_JAR" ]; then
        print_step "Building WeakRefPressureAgent..."
        chmod +x "$AGENT_DIR/build.sh"
        (cd "$AGENT_DIR" && ./build.sh)
        print_success "Agent built successfully"
    fi
}

if [ "$SHOW_RESULTS_ONLY" = false ]; then
    build_agent
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
    local use_agent="${7:-false}"      # optional: use weak ref pressure agent
    
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
    
    local agent_args=""
    local agent_display=""
    if [ "$use_agent" == "true" ]; then
        agent_args=",-javaagent:${AGENT_JAR}=threads=2;refs=1000;delay=10"
        agent_display=" + WeakRefAgent"
    fi
    
    print_step "Running: $jdk_name + $mode mode + $growable_array_display$agent_display + $benchmark_pattern"
    echo "  JDK: $jdk_path"
    echo "  Mode: -Dcaffeine.referenceCleanup=$mode"
    echo "  GrowableArray: $growable_array_flag"
    echo "  JVM opts: $COMMON_JVM_OPTS"
    if [ "$use_agent" == "true" ]; then
        echo "  Agent: WeakRefPressureAgent (2 threads, 1000 refs/batch)"
    fi
    echo "  Benchmark: $benchmark_pattern"
    echo "  CPU cores: $CPU_CORES"
    echo ""
    
    # Run with taskset for CPU pinning and nice for priority
    taskset -c "$CPU_CORES" nice -n -5 \
        ./gradlew jmh -PjavaVersion=27 \
            "-Porg.gradle.java.installations.paths=$jdk_path" \
            -PincludePattern="$benchmark_pattern" \
            "-PjvmArgs=${COMMON_JVM_OPTS},$growable_array_flag,-Dcaffeine.referenceCleanup=$mode$agent_args" \
            --rerun -q 2>&1 | tee "$output_file"
    
    print_success "Completed: $jdk_name + $mode mode + $growable_array_display$agent_display + $benchmark_pattern"
    echo ""
}

# Function to extract Caffeine-specific results
extract_caffeine_results() {
    local file="$1"
    grep -E "^(GetPutWeakRefBenchmark|PutRemoveWeakRefBenchmark|ComputeWeakRefBenchmark|EvictionWeakRefBenchmark)\." "$file" || true
}

# Function to extract all main benchmark results (not sub-benchmarks)
extract_main_results() {
    local file="$1"
    grep -E "^(GetPutWeakRefBenchmark|PutRemoveWeakRefBenchmark|ComputeWeakRefBenchmark|EvictionWeakRefBenchmark)\." "$file" || true
}

print_header "CAFFEINE BENCHMARK SUITE"

# Prime Gradle/JMH/JIT so the first measured configuration is not advantaged
prime_benchmarks() {
    print_header "Priming build/JMH (discarded)"

    # Use the custom JDK and a single, short benchmark to warm Gradle, class loading,
    # JIT, and JVM startup costs. Results are intentionally ignored.
    export JAVA_HOME="$CUSTOM_JDK"
    export PATH="$JAVA_HOME/bin:$PATH"

    taskset -c "$CPU_CORES" nice -n -5 \
        ./gradlew jmh -PjavaVersion=27 \
            "-Porg.gradle.java.installations.paths=$CUSTOM_JDK" \
            -PincludePattern="GetPutWeakRefBenchmark" \
            "-PjvmArgs=${COMMON_JVM_OPTS},-XX:+ZUseGrowableArrayDiscoveredList,-Dcaffeine.referenceCleanup=queue" \
            -PwarmupIterations=1 -PmeasurementIterations=1 -Pfork=1 \
            --rerun -q > /dev/null 2>&1 || true

    print_success "Priming run completed; results discarded"
}

# Count enabled configurations
ENABLED_CONFIGS=0
if [ "$RUN_QUEUE_GROWABLE_ON" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_QUEUE_GROWABLE_ON_AGENT" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_QUEUE_GROWABLE_OFF" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_QUEUE_GROWABLE_OFF_AGENT" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_POLL_GROWABLE_ON" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_POLL_GROWABLE_ON_AGENT" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_POLL_GROWABLE_OFF" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi
if [ "$RUN_POLL_GROWABLE_OFF_AGENT" = "true" ]; then ENABLED_CONFIGS=$((ENABLED_CONFIGS + 1)); fi

if [ "$SHOW_RESULTS_ONLY" = true ]; then
    echo "Displaying previous benchmark results..."
    echo ""
    
    # Check if at least one result file exists
    result_found=false
    for file in "${RESULTS_DIR}"/custom_*.txt; do
        if [ -f "$file" ]; then
            result_found=true
            break
        fi
    done
    
    if [ "$result_found" = false ]; then
        echo -e "${RED}Error: No benchmark results found${NC}"
        echo "Please run benchmarks first without --results flag"
        exit 1
    fi
else
    if [ $ENABLED_CONFIGS -eq 0 ]; then
        echo -e "${RED}Error: No configurations enabled in $CONFIG_FILE${NC}"
        echo "Please enable at least one configuration"
        exit 1
    fi
    
    echo "Testing $ENABLED_CONFIGS enabled configuration(s):"
    echo "  Queue/Poll × GrowableArray ON/OFF × Agent ON/OFF"
    echo ""
    if [ "$RUN_QUEUE_GROWABLE_ON" = "true" ]; then
        echo "  ✓ Queue + GrowableArray ON"
    fi
    if [ "$RUN_QUEUE_GROWABLE_ON_AGENT" = "true" ]; then
        echo "  ✓ Queue + GrowableArray ON + WeakRef Agent"
    fi
    if [ "$RUN_QUEUE_GROWABLE_OFF" = "true" ]; then
        echo "  ✓ Queue + GrowableArray OFF"
    fi
    if [ "$RUN_QUEUE_GROWABLE_OFF_AGENT" = "true" ]; then
        echo "  ✓ Queue + GrowableArray OFF + WeakRef Agent"
    fi
    if [ "$RUN_POLL_GROWABLE_ON" = "true" ]; then
        echo "  ✓ Poll + GrowableArray ON"
    fi
    if [ "$RUN_POLL_GROWABLE_ON_AGENT" = "true" ]; then
        echo "  ✓ Poll + GrowableArray ON + WeakRef Agent"
    fi
    if [ "$RUN_POLL_GROWABLE_OFF" = "true" ]; then
        echo "  ✓ Poll + GrowableArray OFF"
    fi
    if [ "$RUN_POLL_GROWABLE_OFF_AGENT" = "true" ]; then
        echo "  ✓ Poll + GrowableArray OFF + WeakRef Agent"
    fi
    echo ""
    echo "Benchmarks to run:"
    echo "  • GetPutWeakRefBenchmark - Basic get/put operations with weak references"
    echo "  • PutRemoveWeakRefBenchmark - High churn put/remove operations with weak references"
    echo "  • ComputeWeakRefBenchmark - computeIfAbsent operations with weak references"
    echo "  • EvictionWeakRefBenchmark - 100% eviction rate with weak references"
    echo ""
    echo "Custom JDK:   $CUSTOM_JDK"
    echo "Agent:        $AGENT_JAR"
    echo "Config file:  $CONFIG_FILE"
    echo ""
    echo -e "${BOLD}Environment Settings:${NC}"
    echo "  CPU cores:    $CPU_CORES"
    echo "  Cooldown:     ${COOLDOWN_SECONDS}s between runs"
    echo "  CPU pinning:  taskset -c $CPU_CORES"
    echo "  Priority:     nice -n -5"
    echo "  JVM opts:     $COMMON_JVM_OPTS"
    echo ""

    # Try to set CPU governor to performance mode
    setup_cpu_performance
    
    # Trap to restore CPU governor on exit
    trap restore_cpu_governor EXIT

    # prepare environment before starting benchmarks
    prepare_environment

    # Warm everything up so later runs are not penalized
    prime_benchmarks
    
    
    # List of benchmarks to run
    BENCHMARKS=(
        "GetPutWeakRefBenchmark"
        "PutRemoveWeakRefBenchmark"
        "ComputeWeakRefBenchmark"
        "EvictionWeakRefBenchmark"
    )
    
    # Run all benchmarks for enabled configurations
    BENCHMARK_PATTERN=$(IFS='|'; echo "${BENCHMARKS[*]}")
    
    CURRENT_CONFIG=0
    
    if [ "$RUN_QUEUE_GROWABLE_ON" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Queue Mode + GrowableArray ON"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "queue" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_queue_growable_on.txt" "enabled"
    fi
    
    if [ "$RUN_QUEUE_GROWABLE_ON_AGENT" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Queue Mode + GrowableArray ON + WeakRef Agent"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "queue" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_queue_growable_on_agent.txt" "enabled" "true"
    fi
    
    if [ "$RUN_QUEUE_GROWABLE_OFF" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Queue Mode + GrowableArray OFF"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "queue" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_queue_growable_off.txt" "disabled"
    fi
    
    if [ "$RUN_QUEUE_GROWABLE_OFF_AGENT" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Queue Mode + GrowableArray OFF + WeakRef Agent"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "queue" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_queue_growable_off_agent.txt" "disabled" "true"
    fi
    
    if [ "$RUN_POLL_GROWABLE_ON" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Poll Mode + GrowableArray ON"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_poll_growable_on.txt" "enabled"
    fi
    
    if [ "$RUN_POLL_GROWABLE_ON_AGENT" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Poll Mode + GrowableArray ON + WeakRef Agent"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_poll_growable_on_agent.txt" "enabled" "true"
    fi
    
    if [ "$RUN_POLL_GROWABLE_OFF" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Poll Mode + GrowableArray OFF"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_poll_growable_off.txt" "disabled"
    fi
    
    if [ "$RUN_POLL_GROWABLE_OFF_AGENT" = "true" ]; then
        CURRENT_CONFIG=$((CURRENT_CONFIG + 1))
        print_header "$CURRENT_CONFIG/$ENABLED_CONFIGS: Custom JDK + Poll Mode + GrowableArray OFF + WeakRef Agent"
        run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "$BENCHMARK_PATTERN" "${RESULTS_DIR}/custom_poll_growable_off_agent.txt" "disabled" "true"
    fi
fi

# Generate summary report
print_header "BENCHMARK RESULTS SUMMARY"

echo -e "${BOLD}Caffeine Cache Performance (ops/s - higher is better)${NC}"
echo ""

 # Compare all eight configurations for Custom JDK
echo -e "${BOLD}Full Configuration Comparison (Custom JDK)${NC}"
echo "Queue/Poll Mode × GrowableArray ON/OFF × Agent ON/OFF"
echo "────────────────────────────────────────────────────"
echo ""

if [ -f "${RESULTS_DIR}/custom_queue_growable_on.txt" ] && [ -f "${RESULTS_DIR}/custom_poll_growable_on.txt" ]; then
    # Get all unique benchmark names
    benchmarks=$(grep -E "^(GetPutWeakRefBenchmark|PutRemoveWeakRefBenchmark|ComputeWeakRefBenchmark|EvictionWeakRefBenchmark)\." "${RESULTS_DIR}/custom_queue_growable_on.txt" | awk '{print $1}' | sort -u)
    
    while IFS= read -r bench; do
        # Get all matches for this benchmark from all eight configurations
        mapfile -t queue_on_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_queue_growable_on.txt" 2>/dev/null || true)
        mapfile -t queue_on_agent_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_queue_growable_on_agent.txt" 2>/dev/null || true)
        mapfile -t queue_off_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_queue_growable_off.txt" 2>/dev/null || true)
        mapfile -t queue_off_agent_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_queue_growable_off_agent.txt" 2>/dev/null || true)
        mapfile -t poll_on_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_poll_growable_on.txt" 2>/dev/null || true)
        mapfile -t poll_on_agent_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_poll_growable_on_agent.txt" 2>/dev/null || true)
        mapfile -t poll_off_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_poll_growable_off.txt" 2>/dev/null || true)
        mapfile -t poll_off_agent_lines < <(grep "^$bench " "${RESULTS_DIR}/custom_poll_growable_off_agent.txt" 2>/dev/null || true)
        
        if [ ${#queue_on_lines[@]} -eq 0 ] && [ ${#queue_on_agent_lines[@]} -eq 0 ] && \
           [ ${#queue_off_lines[@]} -eq 0 ] && [ ${#queue_off_agent_lines[@]} -eq 0 ] && \
           [ ${#poll_on_lines[@]} -eq 0 ] && [ ${#poll_on_agent_lines[@]} -eq 0 ] && \
           [ ${#poll_off_lines[@]} -eq 0 ] && [ ${#poll_off_agent_lines[@]} -eq 0 ]; then
            continue
        fi

        echo "  ${bench}:"
        maxn=${#queue_on_lines[@]}
        if [ ${#queue_on_agent_lines[@]} -gt $maxn ]; then maxn=${#queue_on_agent_lines[@]}; fi
        if [ ${#queue_off_lines[@]} -gt $maxn ]; then maxn=${#queue_off_lines[@]}; fi
        if [ ${#queue_off_agent_lines[@]} -gt $maxn ]; then maxn=${#queue_off_agent_lines[@]}; fi
        if [ ${#poll_on_lines[@]} -gt $maxn ]; then maxn=${#poll_on_lines[@]}; fi
        if [ ${#poll_on_agent_lines[@]} -gt $maxn ]; then maxn=${#poll_on_agent_lines[@]}; fi
        if [ ${#poll_off_lines[@]} -gt $maxn ]; then maxn=${#poll_off_lines[@]}; fi
        if [ ${#poll_off_agent_lines[@]} -gt $maxn ]; then maxn=${#poll_off_agent_lines[@]}; fi

        for i in $(seq 0 $((maxn-1))); do
            # Extract scores from each configuration
            qon_score="-"
            qona_score="-"
            qoff_score="-"
            qoffa_score="-"
            pon_score="-"
            pona_score="-"
            poff_score="-"
            poffa_score="-"
            
            if [ $i -lt ${#queue_on_lines[@]} ]; then
                qon_score=$(echo "${queue_on_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#queue_on_agent_lines[@]} ]; then
                qona_score=$(echo "${queue_on_agent_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#queue_off_lines[@]} ]; then
                qoff_score=$(echo "${queue_off_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#queue_off_agent_lines[@]} ]; then
                qoffa_score=$(echo "${queue_off_agent_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#poll_on_lines[@]} ]; then
                pon_score=$(echo "${poll_on_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#poll_on_agent_lines[@]} ]; then
                pona_score=$(echo "${poll_on_agent_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#poll_off_lines[@]} ]; then
                poff_score=$(echo "${poll_off_lines[$i]}" | awk '{print $4}')
            fi
            if [ $i -lt ${#poll_off_agent_lines[@]} ]; then
                poffa_score=$(echo "${poll_off_agent_lines[$i]}" | awk '{print $4}')
            fi

            # format numbers in millions
            qon_M=$([ "$qon_score" != "-" ] && echo "scale=2; $qon_score/1000000" | bc || echo "-")
            qona_M=$([ "$qona_score" != "-" ] && echo "scale=2; $qona_score/1000000" | bc || echo "-")
            qoff_M=$([ "$qoff_score" != "-" ] && echo "scale=2; $qoff_score/1000000" | bc || echo "-")
            qoffa_M=$([ "$qoffa_score" != "-" ] && echo "scale=2; $qoffa_score/1000000" | bc || echo "-")
            pon_M=$([ "$pon_score" != "-" ] && echo "scale=2; $pon_score/1000000" | bc || echo "-")
            pona_M=$([ "$pona_score" != "-" ] && echo "scale=2; $pona_score/1000000" | bc || echo "-")
            poff_M=$([ "$poff_score" != "-" ] && echo "scale=2; $poff_score/1000000" | bc || echo "-")
            poffa_M=$([ "$poffa_score" != "-" ] && echo "scale=2; $poffa_score/1000000" | bc || echo "-")

            printf "    Config %d:\n" "$((i+1))"
            printf "      Queue+GA_ON:       %8sM   Queue+GA_ON+Agent:    %8sM\n" "$qon_M" "$qona_M"
            printf "      Queue+GA_OFF:      %8sM   Queue+GA_OFF+Agent:   %8sM\n" "$qoff_M" "$qoffa_M"
            printf "      Poll+GA_ON:        %8sM   Poll+GA_ON+Agent:     %8sM\n" "$pon_M" "$pona_M"
            printf "      Poll+GA_OFF:       %8sM   Poll+GA_OFF+Agent:    %8sM\n" "$poff_M" "$poffa_M"
        done
        echo ""
    done <<< "$benchmarks"
fi

echo ""

# Full results for all benchmarks
print_header "FULL RESULTS BY CONFIGURATION"

# Build array of configs to show based on what ran or exists
CONFIG_LIST=()
if [ -f "${RESULTS_DIR}/custom_queue_growable_on.txt" ]; then
    CONFIG_LIST+=("custom_queue_growable_on:Custom JDK + Queue + GA_ON")
fi
if [ -f "${RESULTS_DIR}/custom_queue_growable_on_agent.txt" ]; then
    CONFIG_LIST+=("custom_queue_growable_on_agent:Custom JDK + Queue + GA_ON + Agent")
fi
if [ -f "${RESULTS_DIR}/custom_queue_growable_off.txt" ]; then
    CONFIG_LIST+=("custom_queue_growable_off:Custom JDK + Queue + GA_OFF")
fi
if [ -f "${RESULTS_DIR}/custom_queue_growable_off_agent.txt" ]; then
    CONFIG_LIST+=("custom_queue_growable_off_agent:Custom JDK + Queue + GA_OFF + Agent")
fi
if [ -f "${RESULTS_DIR}/custom_poll_growable_on.txt" ]; then
    CONFIG_LIST+=("custom_poll_growable_on:Custom JDK + Poll + GA_ON")
fi
if [ -f "${RESULTS_DIR}/custom_poll_growable_on_agent.txt" ]; then
    CONFIG_LIST+=("custom_poll_growable_on_agent:Custom JDK + Poll + GA_ON + Agent")
fi
if [ -f "${RESULTS_DIR}/custom_poll_growable_off.txt" ]; then
    CONFIG_LIST+=("custom_poll_growable_off:Custom JDK + Poll + GA_OFF")
fi
if [ -f "${RESULTS_DIR}/custom_poll_growable_off_agent.txt" ]; then
    CONFIG_LIST+=("custom_poll_growable_off_agent:Custom JDK + Poll + GA_OFF + Agent")
fi

for config in "${CONFIG_LIST[@]}"; do
    file="${config%%:*}"
    name="${config##*:}"
    
    if [ -f "${RESULTS_DIR}/${file}.txt" ]; then
        echo -e "${CYAN}${name}${NC}"
        echo "────────────────────────────────────────────────────────────────────────"
        extract_main_results "${RESULTS_DIR}/${file}.txt" | while read line; do
            bench=$(echo "$line" | awk '{print $1}')
            mode=$(echo "$line" | awk '{print $2}')
            score=$(echo "$line" | awk '{printf "%.2fM", $4/1000000}')
            error=$(echo "$line" | awk '{printf "±%.2fM", $6/1000000}')
            printf "  %-50s %-15s %12s %12s ops/s\n" "$bench" "$mode" "$score" "$error"
        done
        echo ""
    fi
done

print_header "BENCHMARK COMPLETE"
echo "Raw results saved to:"
for config in "${CONFIG_LIST[@]}"; do
    file="${config%%:*}"
    echo "  ${RESULTS_DIR}/${file}.txt"
done
echo ""
echo "To configure which benchmarks run, edit: $CONFIG_FILE"
echo ""
if [ "$SHOW_RESULTS_ONLY" = false ]; then
    echo "Configurations tested in this run ($ENABLED_CONFIGS total):"
    if [ "$RUN_QUEUE_GROWABLE_ON" = "true" ]; then
        echo "  • Queue + GrowableArray ON"
    fi
    if [ "$RUN_QUEUE_GROWABLE_ON_AGENT" = "true" ]; then
        echo "  • Queue + GrowableArray ON + WeakRef Agent"
    fi
    if [ "$RUN_QUEUE_GROWABLE_OFF" = "true" ]; then
        echo "  • Queue + GrowableArray OFF"
    fi
    if [ "$RUN_QUEUE_GROWABLE_OFF_AGENT" = "true" ]; then
        echo "  • Queue + GrowableArray OFF + WeakRef Agent"
    fi
    if [ "$RUN_POLL_GROWABLE_ON" = "true" ]; then
        echo "  • Poll + GrowableArray ON"
    fi
    if [ "$RUN_POLL_GROWABLE_ON_AGENT" = "true" ]; then
        echo "  • Poll + GrowableArray ON + WeakRef Agent"
    fi
    if [ "$RUN_POLL_GROWABLE_OFF" = "true" ]; then
        echo "  • Poll + GrowableArray OFF"
    fi
    if [ "$RUN_POLL_GROWABLE_OFF_AGENT" = "true" ]; then
        echo "  • Poll + GrowableArray OFF + WeakRef Agent"
    fi
fi
