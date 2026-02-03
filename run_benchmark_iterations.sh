#!/bin/bash

# Script to run WeakRefGcBenchmark multiple times and aggregate results

# Default values
JAVA_BIN="./build/linux-x86_64-server-release/jdk/bin/java"
JAVA_OPTS="-Xms10g -Xmx14g -XX:+UseZGC"
BENCHMARK_CLASS="test/weakrefs/WeakRefGcBenchmark.java"
OUTER_ITERATIONS=5
INNER_ITERATIONS=10

# Parse command line arguments
if [ $# -ge 1 ]; then
    OUTER_ITERATIONS=$1
fi
if [ $# -ge 2 ]; then
    INNER_ITERATIONS=$2
fi

echo "Running benchmark $OUTER_ITERATIONS times with $INNER_ITERATIONS iterations each"
echo "========================================="

# Array to store average GC times from each run
declare -a averages

# Run the benchmark multiple times
for ((run=1; run<=OUTER_ITERATIONS; run++)); do
    echo ""
    echo "=== RUN $run/$OUTER_ITERATIONS ==="
    
    # Run the benchmark and capture output
    output=$($JAVA_BIN $JAVA_OPTS $BENCHMARK_CLASS 2000000 256 4096 250 5000 1024 $INNER_ITERATIONS)
    
    # Display the output
    echo "$output"
    
    # Extract the average GC time from the output
    avg=$(echo "$output" | grep "AVERAGE_GC_TIME_MS:" | awk '{print $2}')
    
    if [ -n "$avg" ]; then
        averages+=("$avg")
        echo "Run $run average: $avg ms"
    else
        echo "WARNING: Could not extract average from run $run"
    fi
done

echo ""
echo "========================================="
echo "FINAL RESULTS"
echo "========================================="

# Calculate the overall average of all averages
if [ ${#averages[@]} -gt 0 ]; then
    total=0
    count=0
    
    echo "Individual run averages:"
    for avg in "${averages[@]}"; do
        count=$((count + 1))
        echo "  Run $count: $avg ms"
        total=$(echo "$total + $avg" | bc)
    done
    
    overall_avg=$(echo "scale=3; $total / ${#averages[@]}" | bc)
    
    # Calculate standard deviation
    sum_sq_diff=0
    for avg in "${averages[@]}"; do
        diff=$(echo "$avg - $overall_avg" | bc)
        sq_diff=$(echo "$diff * $diff" | bc)
        sum_sq_diff=$(echo "$sum_sq_diff + $sq_diff" | bc)
    done
    variance=$(echo "scale=3; $sum_sq_diff / ${#averages[@]}" | bc)
    stddev=$(echo "scale=3; sqrt($variance)" | bc)
    
    echo ""
    echo "Overall average GC time: $overall_avg ms"
    echo "Standard deviation: $stddev ms"
    echo "Min: $(printf '%s\n' "${averages[@]}" | sort -n | head -1) ms"
    echo "Max: $(printf '%s\n' "${averages[@]}" | sort -n | tail -1) ms"
else
    echo "ERROR: No valid results collected"
    exit 1
fi
