#!/bin/bash

# Script to compare benchmark performance between custom JDK and standard OpenJDK

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
    exit 1
fi

# Check if Caffeine directory exists
if [ ! -d "$CAFFEINE_DIR" ]; then
    echo "Error: Caffeine directory not found at $CAFFEINE_DIR"
    exit 1
fi

cd "$CAFFEINE_DIR"

echo "=========================================="
echo "Running benchmark with CUSTOM JDK"
echo "=========================================="
export JAVA_HOME="$CUSTOM_JDK"
export PATH="$JAVA_HOME/bin:$PATH"
echo "Java version:"
java -version
echo ""

export JAVA_OPTS="-XX:+UseZGC"
./gradlew jmh -PincludePattern=GetPutBenchmark 2>&1 | tee "${RESULTS_DIR}/custom_jdk_results.txt"

echo ""
echo "=========================================="
echo "Running benchmark with STANDARD OpenJDK"
echo "=========================================="

# Download and setup OpenJDK 27+7 if not present
STANDARD_JDK="${SCRIPT_DIR}/openjdk-27+7"
if [ ! -d "$STANDARD_JDK" ]; then
    echo "Downloading OpenJDK 27+7..."
    cd "$SCRIPT_DIR"
    wget -q --show-progress "https://download.java.net/java/early_access/jdk27/7/GPL/openjdk-27-ea+7_linux-x64_bin.tar.gz"
    echo "Extracting..."
    tar -xzf openjdk-27-ea+7_linux-x64_bin.tar.gz
    rm openjdk-27-ea+7_linux-x64_bin.tar.gz
    mv jdk-27 openjdk-27+7
    echo "OpenJDK 27+7 downloaded and extracted"
fi

export JAVA_HOME="$STANDARD_JDK"
export PATH="$JAVA_HOME/bin:$PATH"

echo "Java version:"
java -version
echo ""

cd "$CAFFEINE_DIR"

export JAVA_OPTS="-XX:+UseZGC"
./gradlew jmh -PincludePattern=GetPutBenchmark 2>&1 | tee "${RESULTS_DIR}/standard_jdk_results.txt"

echo ""
echo "=========================================="
echo "Benchmark Complete!"
echo "=========================================="
echo "Results saved to:"
echo "  Custom JDK:   ${RESULTS_DIR}/custom_jdk_results.txt"
echo "  Standard JDK: ${RESULTS_DIR}/standard_jdk_results.txt"
echo ""
echo "Compare results with:"
echo "  diff ${RESULTS_DIR}/custom_jdk_results.txt ${RESULTS_DIR}/standard_jdk_results.txt"
