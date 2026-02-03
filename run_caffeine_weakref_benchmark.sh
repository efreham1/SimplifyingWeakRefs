#!/bin/bash

# Script to run Caffeine weak reference memory benchmark with custom JDK build

set -e

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the custom JDK build
JDK_BUILD="${SCRIPT_DIR}/build/linux-x86_64-server-release/jdk"

# Check if the JDK build exists
if [ ! -d "$JDK_BUILD" ]; then
    echo "Error: JDK build not found at $JDK_BUILD"
    echo "Please build the JDK first with: bash configure && make images"
    exit 1
fi

# Path to Caffeine project
CAFFEINE_DIR="${SCRIPT_DIR}/caffeine"

if [ ! -d "$CAFFEINE_DIR" ]; then
    echo "Error: Caffeine directory not found at $CAFFEINE_DIR"
    exit 1
fi

echo "Using custom JDK: $JDK_BUILD"
echo "Running Caffeine weak reference memory benchmark..."
echo ""

# Navigate to Caffeine directory and run the memory benchmark
cd "$CAFFEINE_DIR"

# Set JAVA_HOME to use the custom JDK build
export JAVA_HOME="$JDK_BUILD"
export PATH="$JAVA_HOME/bin:$PATH"

# Verify Java version
echo "Java version:"
java -version
echo ""
echo "Running with ZGC..."
echo ""

# Run the memory overhead benchmark with ZGC
export JAVA_OPTS="-XX:+UseZGC"
./gradlew jmh -PincludePattern=GetPutBenchmark

echo ""
echo "Benchmark completed!"
