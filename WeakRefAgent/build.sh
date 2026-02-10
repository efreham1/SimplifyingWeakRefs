#!/bin/bash
# Build script for WeakRefPressureAgent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building WeakRefPressureAgent..."

# Clean previous build
rm -rf build
mkdir -p build

# Compile
javac -d build src/WeakRefPressureAgent.java

# Create JAR with manifest
cd build
jar cfm ../weakref-agent.jar ../MANIFEST.MF *.class
cd ..

echo "✓ Agent built: $SCRIPT_DIR/weakref-agent.jar"
ls -lh weakref-agent.jar
