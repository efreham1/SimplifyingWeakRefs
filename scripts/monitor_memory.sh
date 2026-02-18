#!/bin/bash
# Memory monitoring script that runs on separate cores
# Monitors total process RSS and GC auxiliary memory from NMT

if [ $# -lt 2 ]; then
    echo "Usage: $0 <java_pid> <output_file> [jcmd_path] [benchmark_log_file]"
    exit 1
fi

JAVA_PID=$1
OUTPUT_FILE=$2
INTERVAL=${3:-2}  # Default 2 second interval
JCMD_PATH="${4:-./build/linux-x86_64-server-release/jdk/bin/jcmd}"
LOG_FILE="${5:-}" # optional benchmark log file to extract current phase

# Create output file with header (add heap_kb and phase columns)
echo "[monitor_start] Monitoring PID $JAVA_PID at ${INTERVAL}s intervals" > "$OUTPUT_FILE"
echo "[monitor_header] timestamp_ms,rss_kb,gc_reserved_kb,gc_committed_kb,heap_kb,phase,iteration" >> "$OUTPUT_FILE"

# Function to get RSS from /proc
get_rss() {
    if [ -f "/proc/$JAVA_PID/status" ]; then
        grep -E '^VmRSS:' "/proc/$JAVA_PID/status" | awk '{print $2}'
    else
        echo "0"
    fi
}

# Function to get GC memory from NMT
get_gc_memory() {
    local output=$($JCMD_PATH $JAVA_PID VM.native_memory summary 2>/dev/null | grep -E '^\-.*GC \(reserved=')
    
    if [ -n "$output" ]; then
        local reserved=$(echo "$output" | grep -oP 'reserved=\K\d+')
        local committed=$(echo "$output" | grep -oP 'committed=\K\d+')
        echo "$reserved,$committed"
    else
        echo "0,0"
    fi
}

get_heap_used_kb() {
    # Get heap usage via jcmd GC.heap_info. Handle ZGC output where heap is typically in GB.
    local out=$($JCMD_PATH $JAVA_PID GC.heap_info 2>/dev/null || true)
    if [ -z "$out" ]; then
        echo "0"
        return
    fi

    # Pattern: "used 5G", "used 1024M", "used 500K", or "used=5G" etc
    # Try with space first: "used 5G"
    local match=$(echo "$out" | grep -oE 'used\s+[0-9]+\s*[GMK]' | head -1)
    if [ -n "$match" ]; then
        local num=$(echo "$match" | grep -oE '[0-9]+' | head -1)
        local unit=$(echo "$match" | grep -oE '[GMK]$')
        
        case "$unit" in
            G) echo $((num * 1024 * 1024)) ;;  # GB to KB
            M) echo $((num * 1024)) ;;          # MB to KB
            K) echo "$num" ;;                   # KB as-is
            *) echo "$num" ;;                   # Fallback
        esac
        return
    fi

    # Try with equals sign: "used=5G"
    match=$(echo "$out" | grep -oE 'used\s*=\s*[0-9]+\s*[GMK]' | head -1)
    if [ -n "$match" ]; then
        local num=$(echo "$match" | grep -oE '[0-9]+' | head -1)
        local unit=$(echo "$match" | grep -oE '[GMK]$')
        
        case "$unit" in
            G) echo $((num * 1024 * 1024)) ;;
            M) echo $((num * 1024)) ;;
            K) echo "$num" ;;
            *) echo "$num" ;;
        esac
        return
    fi

    # Try with colon: "used: 5G"
    match=$(echo "$out" | grep -oE 'used\s*:\s*[0-9]+\s*[GMK]' | head -1)
    if [ -n "$match" ]; then
        local num=$(echo "$match" | grep -oE '[0-9]+' | head -1)
        local unit=$(echo "$match" | grep -oE '[GMK]$')
        
        case "$unit" in
            G) echo $((num * 1024 * 1024)) ;;
            M) echo $((num * 1024)) ;;
            K) echo "$num" ;;
            *) echo "$num" ;;
        esac
        return
    fi

    # Fallback
    echo "0"
}

# Function to get current phase from benchmark log (if provided)
get_phase() {
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        # Look for lines like 'Phase 1:' or 'Phase 4-1:' and return the latest 'Phase X' token
        local phase=$(tail -n 200 "$LOG_FILE" | grep -oP 'Phase\s+\d+(?:-\d+)?' | tail -1 || true)
        if [ -n "$phase" ]; then
            echo "$phase"
            return
        fi
    else
        echo ""
    fi
}

# Function to get current iteration from benchmark log (if provided)
get_iteration() {
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        # Look for lines like 'Iteration 1' and return the latest iteration number
        local iter=$(tail -n 200 "$LOG_FILE" | grep -oP 'Iteration\s+\d+' | tail -1 || true)
        if [ -n "$iter" ]; then
            echo "$iter"
            return
        fi
    else
        echo ""
    fi
}

# Monitor loop
while kill -0 $JAVA_PID 2>/dev/null; do
    TIMESTAMP=$(date +%s%3N)  # milliseconds
    RSS=$(get_rss)
    GC_MEM=$(get_gc_memory)
    HEAP_KB=$(get_heap_used_kb)
    PHASE=$(get_phase)
    ITER=$(get_iteration)

    echo "[monitor_data] $TIMESTAMP,$RSS,$GC_MEM,$HEAP_KB,$PHASE,$ITER" >> "$OUTPUT_FILE"
    
    sleep $INTERVAL
done

echo "[monitor_end] Process $JAVA_PID terminated" >> "$OUTPUT_FILE"
