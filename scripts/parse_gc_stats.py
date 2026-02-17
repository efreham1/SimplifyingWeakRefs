#!/usr/bin/env python3
"""
Parse GC stats from benchmark run logs and create a side-by-side comparison.
"""

import re
import glob
import sys
from collections import defaultdict
from pathlib import Path


def find_latest_log(pattern):
    """Find the most recently modified log file matching the pattern."""
    files = glob.glob(pattern)
    if not files:
        return None
    return max(files, key=lambda f: Path(f).stat().st_mtime)


def parse_gc_stats_file(filename):
    """Parse a run log file and extract GC metrics with their Total Avg/Max values and units."""
    metrics = defaultdict(lambda: {"avg": [], "max": [], "units": ""})
    
    if not Path(filename).exists():
        print(f"Warning: {filename} not found")
        return metrics
    
    with open(filename) as f:
        for line in f:
            # Look for lines containing GC stats
            if "[gc,stats]" not in line:
                continue
            
            line = line.strip()
            
            # Skip header lines
            if any(x in line for x in ["Last 10s", "Avg / Max", "==="]):
                continue
            
            # Remove the [gc,stats] prefix and timestamp
            match = re.search(r'\[gc,stats\](.*)', line)
            if not match:
                continue
            
            data = match.group(1).strip()
            
            # Find all patterns of "number / number"
            value_pattern = r'(\d+\.?\d*)\s*/\s*(\d+\.?\d*)'
            matches = list(re.finditer(value_pattern, data))
            
            if len(matches) < 4:
                continue
            
            # Get the 4th match (index 3) which is the Total Avg/Max
            fourth_match = matches[3]
            total_avg = float(fourth_match.group(1))
            total_max = float(fourth_match.group(2))
            
            # Extract metric name (everything before the first number)
            metric_start = re.search(r'\d', data)
            if not metric_start:
                continue
            
            metric_name = data[:metric_start.start()].strip()
            
            # Extract units from the end of the line (after the last number pair)
            # Units are the last word(s) at the end of the line
            units_match = re.search(r'(\d+\.?\d*)\s*/\s*(\d+\.?\d*)\s+(\S+)\s*$', data)
            units = ""
            if units_match:
                units = units_match.group(3)
            
            if metric_name:
                metrics[metric_name]["avg"].append(total_avg)
                metrics[metric_name]["max"].append(total_max)
                if units:
                    metrics[metric_name]["units"] = units
    
    return metrics


def extract_units(metric_name):
    """Extract units from parsed metric data."""
    # Units are now stored in the metrics dict directly
    return ""


def calculate_averages(metrics):
    """Calculate averages for each metric."""
    averages = {}
    for metric_name, values in metrics.items():
        if values["avg"]:
            averages[metric_name] = {
                "avg": sum(values["avg"]) / len(values["avg"]),
                "max": sum(values["max"]) / len(values["max"]),
                "units": values.get("units", ""),
            }
    return averages


def main():
    # Find the most recent log files in the output directory
    on_log = find_latest_log("output/run_ON_*.log")
    off_log = find_latest_log("output/run_OFF_*.log")
    
    if not on_log or not off_log:
        print("Error: Could not find output/run_ON_*.log and/or output/run_OFF_*.log files")
        print("Make sure you have run the benchmark script first:")
        print("  sudo -E bash run_benchmark_iterations.sh")
        return 1
    
    print("\n" + "=" * 100)
    print(" " * 25 + "COMPREHENSIVE GC STATS COMPARISON (GA ON vs GA OFF)")
    print("=" * 100 + "\n")
    
    # Parse both files
    print(f"Parsing {on_log}...")
    on_metrics = parse_gc_stats_file(on_log)
    on_avgs = calculate_averages(on_metrics)
    print(f"  Found {len(on_avgs)} metrics")
    
    print(f"Parsing {off_log}...")
    off_metrics = parse_gc_stats_file(off_log)
    off_avgs = calculate_averages(off_metrics)
    print(f"  Found {len(off_avgs)} metrics")
    
    print("\n" + "-" * 150)
    
    # Display comparison table with readable formatting for 150+ char line width
    header = f"{'Metric':<50} {'Unit':>8} {'ON Avg':>12} {'ON Max':>12} {'OFF Avg':>12} {'OFF Max':>12} {'AvgDiff%':>12} {'MaxDiff%':>12}"
    print(header)
    print("-" * 150)
    
    # Get all unique metric names, sorted
    all_metrics = sorted(set(on_avgs.keys()) | set(off_avgs.keys()))
    
    for metric in all_metrics:
        on_avg = on_avgs.get(metric, {}).get("avg", None)
        on_max = on_avgs.get(metric, {}).get("max", None)
        off_avg = off_avgs.get(metric, {}).get("avg", None)
        off_max = off_avgs.get(metric, {}).get("max", None)
        
        on_avg_str = f"{on_avg:.2f}" if on_avg is not None else "n/a"
        on_max_str = f"{on_max:.2f}" if on_max is not None else "n/a"
        off_avg_str = f"{off_avg:.2f}" if off_avg is not None else "n/a"
        off_max_str = f"{off_max:.2f}" if off_max is not None else "n/a"
        
        # Get units from the averaged data
        units = on_avgs.get(metric, {}).get("units", "")
        if not units:
            units = off_avgs.get(metric, {}).get("units", "")
        units_str = units if units else "-"
        
        # Cap metric name at 50 characters
        metric_display = metric[:50]
        
        # Calculate diff percentages (OFF - ON) / ON * 100
        if on_avg is not None and off_avg is not None and on_avg != 0:
            avg_diff_pct = (off_avg - on_avg) / on_avg * 100
            avg_diff_str = f"{avg_diff_pct:+.2f}"
        else:
            avg_diff_str = "n/a"
        
        if on_max is not None and off_max is not None and on_max != 0:
            max_diff_pct = (off_max - on_max) / on_max * 100
            max_diff_str = f"{max_diff_pct:+.2f}"
        else:
            max_diff_str = "n/a"
        
        row = f"{metric_display:<50} {units_str:>8} {on_avg_str:>12} {on_max_str:>12} {off_avg_str:>12} {off_max_str:>12} {avg_diff_str:>12} {max_diff_str:>12}"
        print(row)
    
    print("-" * 150)
    print()
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
