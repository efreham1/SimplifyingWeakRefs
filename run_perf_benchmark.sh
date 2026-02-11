#!/bin/bash

# Run a single benchmark configuration with perf profiling
#
# Usage:
#   ./run_perf_benchmark.sh [OPTIONS]
#
# Options:
#   --mode <queue|poll>           Reference cleanup mode (default: queue)
#   --growable <on|off>           GrowableArray option (default: on)
#   --agent <on|off>              Use WeakRefAgent (default: off)
#   --benchmark <pattern>         Benchmark pattern (default: GetPutWeakRefBenchmark)
#   --perf-mode <record|stat>     Perf mode: record or stat (default: record)
#   --output <file>               Output file for perf data (default: auto-generated)
#   --events <events>             Perf events to record (default: cycles,instructions,cache-misses,branches,branch-misses)
#   --help                        Show this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_JDK="${SCRIPT_DIR}/build/linux-x86_64-server-release/jdk"
CAFFEINE_DIR="${SCRIPT_DIR}/caffeine"
PERF_DIR="${SCRIPT_DIR}/perf_results"
AGENT_DIR="${SCRIPT_DIR}/WeakRefAgent"
AGENT_JAR="${AGENT_DIR}/weakref-agent.jar"

# Default parameters
MODE="queue"
GROWABLE="on"
USE_AGENT="off"
BENCHMARK_PATTERN="GetPutWeakRefBenchmark"
PERF_MODE="record"
PERF_OUTPUT=""
PERF_EVENTS="cycles,instructions,cache-misses,branches,branch-misses"

# Benchmark environment settings
CPU_CORES="${CPU_CORES:-0-11}"
COMMON_JVM_OPTS="${COMMON_JVM_OPTS:--XX:+UseZGC,-Xlog:gc*,-XX:InitialTenuringThreshold=1,-XX:MaxTenuringThreshold=1,-XX:+UnlockDiagnosticVMOptions}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
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

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --growable)
            GROWABLE="$2"
            shift 2
            ;;
        --agent)
            USE_AGENT="$2"
            shift 2
            ;;
        --benchmark)
            BENCHMARK_PATTERN="$2"
            shift 2
            ;;
        --perf-mode)
            PERF_MODE="$2"
            shift 2
            ;;
        --output)
            PERF_OUTPUT="$2"
            shift 2
            ;;
        --events)
            PERF_EVENTS="$2"
            shift 2
            ;;
        --help)
            grep "^#" "$0" | grep -v "#!/bin/bash" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate parameters
if [[ "$MODE" != "queue" && "$MODE" != "poll" ]]; then
    print_error "Invalid mode: $MODE (must be 'queue' or 'poll')"
    exit 1
fi

if [[ "$GROWABLE" != "on" && "$GROWABLE" != "off" ]]; then
    print_error "Invalid growable option: $GROWABLE (must be 'on' or 'off')"
    exit 1
fi

if [[ "$USE_AGENT" != "on" && "$USE_AGENT" != "off" ]]; then
    print_error "Invalid agent option: $USE_AGENT (must be 'on' or 'off')"
    exit 1
fi

if [[ "$PERF_MODE" != "record" && "$PERF_MODE" != "stat" ]]; then
    print_error "Invalid perf mode: $PERF_MODE (must be 'record' or 'stat')"
    exit 1
fi

# Check if perf is available
if ! command -v perf &> /dev/null; then
    print_error "perf command not found. Please install linux-tools or perf package."
    exit 1
fi

# Create output directory
mkdir -p "$PERF_DIR"

# Check if custom JDK exists
if [ ! -d "$CUSTOM_JDK" ]; then
    print_error "Custom JDK build not found at $CUSTOM_JDK"
    echo "Please build the JDK first with: bash configure && make images"
    exit 1
fi

# Check if Caffeine directory exists
if [ ! -d "$CAFFEINE_DIR" ]; then
    print_error "Caffeine directory not found at $CAFFEINE_DIR"
    exit 1
fi

# Build WeakRefAgent if needed
if [ "$USE_AGENT" == "on" ] && [ ! -f "$AGENT_JAR" ]; then
    print_step "Building WeakRefPressureAgent..."
    chmod +x "$AGENT_DIR/build.sh"
    (cd "$AGENT_DIR" && ./build.sh)
    print_success "Agent built successfully"
fi

# Setup JDK
export JAVA_HOME="$CUSTOM_JDK"
export PATH="$JAVA_HOME/bin:$PATH"

# Setup growable array flag
if [ "$GROWABLE" == "on" ]; then
    GROWABLE_FLAG="-XX:+ZUseGrowableArrayDiscoveredList"
    GROWABLE_DISPLAY="GrowableArray=ON"
else
    GROWABLE_FLAG="-XX:-ZUseGrowableArrayDiscoveredList"
    GROWABLE_DISPLAY="GrowableArray=OFF"
fi

# Setup agent
AGENT_ARGS=""
AGENT_DISPLAY=""
if [ "$USE_AGENT" == "on" ]; then
    AGENT_ARGS=",-javaagent:${AGENT_JAR}=threads=2;refs=1000;delay=10"
    AGENT_DISPLAY=" + WeakRefAgent"
fi

# Generate output filename if not specified
if [ -z "$PERF_OUTPUT" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    PERF_OUTPUT="${PERF_DIR}/perf_${MODE}_growable_${GROWABLE}_agent_${USE_AGENT}_${TIMESTAMP}"
fi

print_header "PERF BENCHMARK PROFILING"

echo -e "${BOLD}Configuration:${NC}"
echo "  Mode:         $MODE"
echo "  GrowableArray: $GROWABLE ($GROWABLE_FLAG)"
echo "  Agent:        $USE_AGENT$AGENT_DISPLAY"
echo "  Benchmark:    $BENCHMARK_PATTERN"
echo "  Perf mode:    $PERF_MODE"
if [ "$PERF_MODE" == "record" ]; then
    echo "  Events:       $PERF_EVENTS"
fi
echo "  Output:       $PERF_OUTPUT"
echo "  CPU cores:    $CPU_CORES"
echo "  JVM opts:     $COMMON_JVM_OPTS"
echo ""

cd "$CAFFEINE_DIR"

# Stop Gradle daemon to ensure clean state
print_step "Stopping Gradle daemon..."
./gradlew --stop 2>/dev/null || true

# Prepare environment
print_step "Dropping caches and preparing environment..."
if command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
fi
sleep 2

# Build perf command
GRADLE_CMD="./gradlew jmh -PjavaVersion=27 \
    -Porg.gradle.java.installations.paths=$CUSTOM_JDK \
    -PincludePattern=\"$BENCHMARK_PATTERN\" \
    -PjvmArgs=\"${COMMON_JVM_OPTS},$GROWABLE_FLAG,-Dcaffeine.referenceCleanup=$MODE$AGENT_ARGS\" \
    --rerun -q"

if [ "$PERF_MODE" == "record" ]; then
    print_step "Running benchmark with perf record..."
    echo "  Recording events: $PERF_EVENTS"
    echo ""
    
    # Run with perf record
    taskset -c "$CPU_CORES" nice -n -5 \
        perf record -e "$PERF_EVENTS" -g --call-graph dwarf -F 99 \
        -o "${PERF_OUTPUT}.data" \
        -- bash -c "$GRADLE_CMD" 2>&1 | tee "${PERF_OUTPUT}.log"
    
    print_success "Perf data recorded to ${PERF_OUTPUT}.data"
    
    # Generate report
    print_step "Generating perf report..."
    perf report -i "${PERF_OUTPUT}.data" --stdio > "${PERF_OUTPUT}.report.txt" 2>&1
    print_success "Perf report saved to ${PERF_OUTPUT}.report.txt"
    
    echo ""
    echo -e "${BOLD}To view interactive report:${NC}"
    echo "  perf report -i ${PERF_OUTPUT}.data"
    echo ""
    echo -e "${BOLD}To generate flamegraph:${NC}"
    echo "  perf script -i ${PERF_OUTPUT}.data > ${PERF_OUTPUT}.perf-script"
    echo "  stackcollapse-perf.pl ${PERF_OUTPUT}.perf-script > ${PERF_OUTPUT}.folded"
    echo "  flamegraph.pl ${PERF_OUTPUT}.folded > ${PERF_OUTPUT}.svg"
    
elif [ "$PERF_MODE" == "stat" ]; then
    print_step "Running benchmark with perf stat..."
    echo ""
    
    # Run with perf stat
    taskset -c "$CPU_CORES" nice -n -5 \
        perf stat -e "$PERF_EVENTS" -d -d -d \
        -o "${PERF_OUTPUT}.stat.txt" \
        -- bash -c "$GRADLE_CMD" 2>&1 | tee "${PERF_OUTPUT}.log"
    
    print_success "Perf stats saved to ${PERF_OUTPUT}.stat.txt"
    
    # Display the stats
    echo ""
    echo -e "${BOLD}Performance Statistics:${NC}"
    cat "${PERF_OUTPUT}.stat.txt"
fi

print_header "PROFILING COMPLETE"

echo "Output files:"
if [ "$PERF_MODE" == "record" ]; then
    echo "  ${PERF_OUTPUT}.data          - Perf data file"
    echo "  ${PERF_OUTPUT}.report.txt    - Text report"
    echo "  ${PERF_OUTPUT}.log           - Benchmark output"
else
    echo "  ${PERF_OUTPUT}.stat.txt      - Performance statistics"
    echo "  ${PERF_OUTPUT}.log           - Benchmark output"
fi

echo ""
print_success "Done!"
