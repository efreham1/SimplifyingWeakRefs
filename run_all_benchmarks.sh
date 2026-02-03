#!/bin/bash

# Comprehensive benchmark script comparing all four configurations:
# 1. Custom JDK + Queue mode (ReferenceQueue-based cleanup)
# 2. Custom JDK + Poll mode (Scan-based cleanup, no ReferenceQueue)
# 3. Standard OpenJDK + Queue mode
# 4. Standard OpenJDK + Poll mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_JDK="${SCRIPT_DIR}/build/linux-x86_64-server-release/jdk"
CAFFEINE_DIR="${SCRIPT_DIR}/caffeine"
RESULTS_DIR="${SCRIPT_DIR}/benchmark_results"
STANDARD_JDK="${SCRIPT_DIR}/openjdk-27+7"

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

# Download standard OpenJDK if not present
if [ ! -d "$STANDARD_JDK" ]; then
    print_header "Downloading Standard OpenJDK 27+7"
    cd "$SCRIPT_DIR"
    wget -q --show-progress "https://download.java.net/java/early_access/jdk27/7/GPL/openjdk-27-ea+7_linux-x64_bin.tar.gz"
    echo "Extracting..."
    tar -xzf openjdk-27-ea+7_linux-x64_bin.tar.gz
    rm openjdk-27-ea+7_linux-x64_bin.tar.gz
    mv jdk-27 openjdk-27+7
    print_success "OpenJDK 27+7 downloaded and extracted"
fi

cd "$CAFFEINE_DIR"

# Function to run benchmark
run_benchmark() {
    local jdk_path="$1"
    local jdk_name="$2"
    local mode="$3"
    local output_file="$4"
    
    # Prepare environment before each run
    prepare_environment
    
    export JAVA_HOME="$jdk_path"
    export PATH="$JAVA_HOME/bin:$PATH"
    
    print_step "Running: $jdk_name + $mode mode"
    echo "  JDK: $jdk_path"
    echo "  Mode: -Dcaffeine.referenceCleanup=$mode"
    echo "  CPU cores: $CPU_CORES"
    echo ""
    
    # Run with taskset for CPU pinning and nice for priority
    taskset -c "$CPU_CORES" nice -n -5 \
        ./gradlew jmh -PjavaVersion=27 \
            "-Porg.gradle.java.installations.paths=$jdk_path" \
            -PincludePattern=GetPutBenchmark \
            "-PbenchmarkParameters=cacheType=Caffeine" \
            "-PjvmArgs=-XX:+UseZGC,-Dcaffeine.referenceCleanup=$mode" \
            --rerun -q 2>&1 | tee "$output_file"
    
    print_success "Completed: $jdk_name + $mode mode"
    echo ""
}

# Function to extract Caffeine-specific results
extract_caffeine_results() {
    local file="$1"
    grep "Caffeine" "$file" | grep -E "^GetPutBenchmark\.(read_only|write_only|readwrite) " || true
}

# Function to extract all main benchmark results (not sub-benchmarks)
extract_main_results() {
    local file="$1"
    grep -E "^GetPutBenchmark\.(read_only|write_only|readwrite) " "$file" || true
}

print_header "CAFFEINE BENCHMARK SUITE"
echo "Testing all four configurations:"
echo "  1. Custom JDK + Queue mode (ReferenceQueue-based)"
echo "  2. Custom JDK + Poll mode (Scan-based, no ReferenceQueue)"
echo "  3. Standard OpenJDK 27+7 + Queue mode"
echo "  4. Standard OpenJDK 27+7 + Poll mode"
echo ""
echo "Custom JDK:   $CUSTOM_JDK"
echo "Standard JDK: $STANDARD_JDK"
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

# Run all four benchmarks
print_header "1/4: Custom JDK + Queue Mode"
run_benchmark "$CUSTOM_JDK" "Custom JDK" "queue" "${RESULTS_DIR}/custom_queue.txt"

print_header "2/4: Custom JDK + Poll Mode"
run_benchmark "$CUSTOM_JDK" "Custom JDK" "poll" "${RESULTS_DIR}/custom_poll.txt"

print_header "3/4: Standard OpenJDK + Queue Mode"
run_benchmark "$STANDARD_JDK" "Standard OpenJDK" "queue" "${RESULTS_DIR}/standard_queue.txt"

print_header "4/4: Standard OpenJDK + Poll Mode"
run_benchmark "$STANDARD_JDK" "Standard OpenJDK" "poll" "${RESULTS_DIR}/standard_poll.txt"

# Generate summary report
print_header "BENCHMARK RESULTS SUMMARY"

echo -e "${BOLD}Caffeine Cache Performance (ops/s - higher is better)${NC}"
echo ""

# Create a formatted comparison table
echo "┌────────────────────────────────────────────────────────────────────────────────────┐"
echo "│                           CAFFEINE BENCHMARK RESULTS                               │"
echo "├────────────────────────────────────────────────────────────────────────────────────┤"
printf "│ %-20s │ %-14s │ %-14s │ %-14s │ %-10s │\n" "Configuration" "read_only" "write_only" "readwrite" "Change"
echo "├────────────────────────────────────────────────────────────────────────────────────┤"

# Extract Caffeine results for each configuration
for config in "custom_queue:Custom+Queue" "custom_poll:Custom+Poll" "standard_queue:Standard+Queue" "standard_poll:Standard+Poll"; do
    file="${config%%:*}"
    name="${config##*:}"
    
    if [ -f "${RESULTS_DIR}/${file}.txt" ]; then
        read_only=$(grep "^GetPutBenchmark.read_only " "${RESULTS_DIR}/${file}.txt" | grep "Caffeine" | awk '{printf "%.1fM", $5/1000000}')
        write_only=$(grep "^GetPutBenchmark.write_only " "${RESULTS_DIR}/${file}.txt" | grep "Caffeine" | awk '{printf "%.1fM", $5/1000000}')
        readwrite=$(grep "^GetPutBenchmark.readwrite " "${RESULTS_DIR}/${file}.txt" | grep "Caffeine" | awk '{printf "%.1fM", $5/1000000}')
        
        [ -z "$read_only" ] && read_only="N/A"
        [ -z "$write_only" ] && write_only="N/A"
        [ -z "$readwrite" ] && readwrite="N/A"
        
        printf "│ %-20s │ %14s │ %14s │ %14s │ %10s │\n" "$name" "$read_only" "$write_only" "$readwrite" "-"
    else
        printf "│ %-20s │ %14s │ %14s │ %14s │ %10s │\n" "$name" "N/A" "N/A" "N/A" "-"
    fi
done

echo "└────────────────────────────────────────────────────────────────────────────────────┘"
echo ""

# Compare Queue vs Poll for Custom JDK
echo -e "${BOLD}Queue vs Poll Comparison (Custom JDK)${NC}"
echo "────────────────────────────────────────"

if [ -f "${RESULTS_DIR}/custom_queue.txt" ] && [ -f "${RESULTS_DIR}/custom_poll.txt" ]; then
    queue_read=$(grep "^GetPutBenchmark.read_only " "${RESULTS_DIR}/custom_queue.txt" | grep "Caffeine" | awk '{print $5}')
    poll_read=$(grep "^GetPutBenchmark.read_only " "${RESULTS_DIR}/custom_poll.txt" | grep "Caffeine" | awk '{print $5}')
    
    queue_write=$(grep "^GetPutBenchmark.write_only " "${RESULTS_DIR}/custom_queue.txt" | grep "Caffeine" | awk '{print $5}')
    poll_write=$(grep "^GetPutBenchmark.write_only " "${RESULTS_DIR}/custom_poll.txt" | grep "Caffeine" | awk '{print $5}')
    
    queue_rw=$(grep "^GetPutBenchmark.readwrite " "${RESULTS_DIR}/custom_queue.txt" | grep "Caffeine" | awk '{print $5}')
    poll_rw=$(grep "^GetPutBenchmark.readwrite " "${RESULTS_DIR}/custom_poll.txt" | grep "Caffeine" | awk '{print $5}')
    
    if [ -n "$queue_read" ] && [ -n "$poll_read" ]; then
        diff_read=$(echo "scale=2; (($poll_read - $queue_read) / $queue_read) * 100" | bc 2>/dev/null || echo "N/A")
        echo "  read_only:  Queue=$(echo "scale=1; $queue_read/1000000" | bc)M  Poll=$(echo "scale=1; $poll_read/1000000" | bc)M  Diff: ${diff_read}%"
    fi
    
    if [ -n "$queue_write" ] && [ -n "$poll_write" ]; then
        diff_write=$(echo "scale=2; (($poll_write - $queue_write) / $queue_write) * 100" | bc 2>/dev/null || echo "N/A")
        echo "  write_only: Queue=$(echo "scale=1; $queue_write/1000000" | bc)M  Poll=$(echo "scale=1; $poll_write/1000000" | bc)M  Diff: ${diff_write}%"
    fi
    
    if [ -n "$queue_rw" ] && [ -n "$poll_rw" ]; then
        diff_rw=$(echo "scale=2; (($poll_rw - $queue_rw) / $queue_rw) * 100" | bc 2>/dev/null || echo "N/A")
        echo "  readwrite:  Queue=$(echo "scale=1; $queue_rw/1000000" | bc)M  Poll=$(echo "scale=1; $poll_rw/1000000" | bc)M  Diff: ${diff_rw}%"
    fi
fi

echo ""

# Compare Custom JDK vs Standard JDK (both using queue mode)
echo -e "${BOLD}Custom JDK vs Standard OpenJDK (Queue Mode)${NC}"
echo "────────────────────────────────────────────"

if [ -f "${RESULTS_DIR}/custom_queue.txt" ] && [ -f "${RESULTS_DIR}/standard_queue.txt" ]; then
    custom_read=$(grep "^GetPutBenchmark.read_only " "${RESULTS_DIR}/custom_queue.txt" | grep "Caffeine" | awk '{print $5}')
    std_read=$(grep "^GetPutBenchmark.read_only " "${RESULTS_DIR}/standard_queue.txt" | grep "Caffeine" | awk '{print $5}')
    
    custom_write=$(grep "^GetPutBenchmark.write_only " "${RESULTS_DIR}/custom_queue.txt" | grep "Caffeine" | awk '{print $5}')
    std_write=$(grep "^GetPutBenchmark.write_only " "${RESULTS_DIR}/standard_queue.txt" | grep "Caffeine" | awk '{print $5}')
    
    custom_rw=$(grep "^GetPutBenchmark.readwrite " "${RESULTS_DIR}/custom_queue.txt" | grep "Caffeine" | awk '{print $5}')
    std_rw=$(grep "^GetPutBenchmark.readwrite " "${RESULTS_DIR}/standard_queue.txt" | grep "Caffeine" | awk '{print $5}')
    
    if [ -n "$custom_read" ] && [ -n "$std_read" ]; then
        diff_read=$(echo "scale=2; (($custom_read - $std_read) / $std_read) * 100" | bc 2>/dev/null || echo "N/A")
        echo "  read_only:  Custom=$(echo "scale=1; $custom_read/1000000" | bc)M  Standard=$(echo "scale=1; $std_read/1000000" | bc)M  Diff: ${diff_read}%"
    fi
    
    if [ -n "$custom_write" ] && [ -n "$std_write" ]; then
        diff_write=$(echo "scale=2; (($custom_write - $std_write) / $std_write) * 100" | bc 2>/dev/null || echo "N/A")
        echo "  write_only: Custom=$(echo "scale=1; $custom_write/1000000" | bc)M  Standard=$(echo "scale=1; $std_write/1000000" | bc)M  Diff: ${diff_write}%"
    fi
    
    if [ -n "$custom_rw" ] && [ -n "$std_rw" ]; then
        diff_rw=$(echo "scale=2; (($custom_rw - $std_rw) / $std_rw) * 100" | bc 2>/dev/null || echo "N/A")
        echo "  readwrite:  Custom=$(echo "scale=1; $custom_rw/1000000" | bc)M  Standard=$(echo "scale=1; $std_rw/1000000" | bc)M  Diff: ${diff_rw}%"
    fi
fi

echo ""

# Full results for all cache types
print_header "FULL RESULTS BY CACHE TYPE"

for config in "custom_queue:Custom JDK + Queue" "custom_poll:Custom JDK + Poll" "standard_queue:Standard JDK + Queue" "standard_poll:Standard JDK + Poll"; do
    file="${config%%:*}"
    name="${config##*:}"
    
    if [ -f "${RESULTS_DIR}/${file}.txt" ]; then
        echo -e "${CYAN}${name}${NC}"
        echo "────────────────────────────────────────"
        extract_main_results "${RESULTS_DIR}/${file}.txt" | while read line; do
            bench=$(echo "$line" | awk '{print $1}')
            cache=$(echo "$line" | awk '{print $2}')
            score=$(echo "$line" | awk '{printf "%.2fM", $5/1000000}')
            error=$(echo "$line" | awk '{printf "±%.2fM", $7/1000000}')
            printf "  %-15s %-25s %12s %12s ops/s\n" "$bench" "$cache" "$score" "$error"
        done
        echo ""
    fi
done

print_header "BENCHMARK COMPLETE"
echo "Raw results saved to:"
echo "  ${RESULTS_DIR}/custom_queue.txt"
echo "  ${RESULTS_DIR}/custom_poll.txt"
echo "  ${RESULTS_DIR}/standard_queue.txt"
echo "  ${RESULTS_DIR}/standard_poll.txt"
echo ""
echo "Note: Positive % difference means the first option is faster"
