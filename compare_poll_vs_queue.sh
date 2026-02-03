#!/bin/bash

# Script to compare poll vs queue reference cleanup implementations using the custom JDK
# This tests the performance difference between:
# - POLL mode: Scans all entries and checks .get() == null (no ReferenceQueue)
# - QUEUE mode: Uses ReferenceQueue.poll() for efficient GC-driven cleanup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_JDK="${SCRIPT_DIR}/build/linux-x86_64-server-release/jdk"
CAFFEINE_DIR="${SCRIPT_DIR}/caffeine"
RESULTS_DIR="${SCRIPT_DIR}/benchmark_results"

# Create results directory
mkdir -p "$RESULTS_DIR"

# Check if custom JDK exists
if [ ! -d "$CUSTOM_JDK" ]; then
    echo "Error: Custom JDK build not found at $CUSTOM_JDK"
    echo "Please build the JDK first with: bash configure && make images"
    exit 1
fi

# Check if Caffeine directory exists
if [ ! -d "$CAFFEINE_DIR" ]; then
    echo "Error: Caffeine directory not found at $CAFFEINE_DIR"
    exit 1
fi

cd "$CAFFEINE_DIR"

# Use custom JDK for both tests
export JAVA_HOME="$CUSTOM_JDK"
export PATH="$JAVA_HOME/bin:$PATH"

echo "Using custom JDK:"
java -version
echo ""

echo "=========================================="
echo "TEST 1: QUEUE MODE (ReferenceQueue-based cleanup)"
echo "=========================================="
echo "Using -Dcaffeine.referenceCleanup=queue"
echo ""

# Use javaVersion=27 and pass custom JDK path to Gradle toolchain
./gradlew jmh -PjavaVersion=27 "-Porg.gradle.java.installations.paths=$CUSTOM_JDK" -PincludePattern=GetPutBenchmark "-PbenchmarkParameters=cacheType=Caffeine" -PjvmArgs="-XX:+UseZGC,-Dcaffeine.referenceCleanup=queue" --rerun 2>&1 | tee "${RESULTS_DIR}/queue_mode_results.txt"

echo ""
echo "=========================================="
echo "TEST 2: POLL MODE (Scan-based cleanup, no ReferenceQueue)"
echo "=========================================="
echo "Using -Dcaffeine.referenceCleanup=poll"
echo ""

# Use javaVersion=27 and pass custom JDK path to Gradle toolchain
./gradlew jmh -PjavaVersion=27 "-Porg.gradle.java.installations.paths=$CUSTOM_JDK" -PincludePattern=GetPutBenchmark "-PbenchmarkParameters=cacheType=Caffeine" -PjvmArgs="-XX:+UseZGC,-Dcaffeine.referenceCleanup=poll" --rerun 2>&1 | tee "${RESULTS_DIR}/poll_mode_results.txt"

echo ""
echo "=========================================="
echo "Comparison Complete!"
echo "=========================================="
echo ""
echo "Results saved to:"
echo "  Queue mode (ReferenceQueue): ${RESULTS_DIR}/queue_mode_results.txt"
echo "  Poll mode (scan):            ${RESULTS_DIR}/poll_mode_results.txt"
echo ""
echo "Compare results with:"
echo "  diff ${RESULTS_DIR}/queue_mode_results.txt ${RESULTS_DIR}/poll_mode_results.txt"
echo ""
echo "Note: Poll mode scans ALL entries during maintenance, which is O(n) vs O(cleared entries)"
echo "      for queue mode. Performance difference will be more pronounced with larger caches"
echo "      and more frequent GC cycles."
