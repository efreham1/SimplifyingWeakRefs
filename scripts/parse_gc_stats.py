#!/usr/bin/env python3
"""
Parse continuous memory monitoring data and generate plots.
Aggregates data across outer runs with run tracking.
"""

import glob
import re
import sys
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np


def extract_run_num(filename):
    """Extract run number from filename like 'run_ON_run2_1.log'.
    
    Returns run number as int, or None if not found.
    """
    match = re.search(r'_run(\d+)_', filename)
    if match:
        return int(match.group(1))
    return None


def parse_continuous_monitor_data(filename):
    """Parse continuous memory monitoring data from CSV file."""
    monitor_data = []
    
    if not Path(filename).exists():
        print(f"Warning: {filename} not found")
        return monitor_data
    
    with open(filename) as f:
        for line in f:
            if "[monitor_data]" in line:
                # Format: [monitor_data] timestamp_ms,rss_kb,gc_reserved_kb,gc_committed_kb,heap_kb,phase,iteration
                parts = line.split(']', 1)[1].strip().split(',')
                # Need at least 5 parts (timestamp, rss, gc_reserved, gc_committed, heap)
                if len(parts) >= 5:
                    try:
                        # Try to parse timestamp - skip if it fails (empty lines at end)
                        ts = int(parts[0]) if parts[0].strip() else None
                        if ts is None:
                            continue
                            
                        entry = {
                            'timestamp_ms': ts,
                            'rss_kb': int(parts[1]) if parts[1].strip() else 0,
                            'gc_reserved_kb': int(parts[2]) if parts[2].strip() else 0,
                            'gc_committed_kb': int(parts[3]) if parts[3].strip() else 0,
                            'heap_kb': int(parts[4]) if parts[4].strip() else 0
                        }
                        entry['phase'] = parts[5].strip() if len(parts) >= 6 else ""
                        # Parse iteration from 7th column if present
                        entry['iteration'] = parts[6].strip() if len(parts) >= 7 else ""
                        monitor_data.append(entry)
                    except (ValueError, IndexError):
                        continue
    
    return monitor_data


def load_monitor_file(filename):
    """Load a single monitor CSV into arrays and extract per-run phase first-seen times.

    Returns: times_ms (np.array), rss_kb (np.array), gc_committed_kb (np.array), phase_map (dict phase->time_ms)
    """
    data = parse_continuous_monitor_data(filename)
    if not data:
        return None, None, None, None, {}

    times = np.array([d['timestamp_ms'] for d in data], dtype=float)
    times = times - times[0]
    rss = np.array([d['rss_kb'] for d in data], dtype=float)
    gc = np.array([d.get('gc_committed_kb', d.get('gc_committed', 0)) if isinstance(d.get('gc_committed_kb', None), (int, float)) else d.get('gc_committed_kb', 0) for d in data], dtype=float)
    heap = np.array([d.get('heap_kb', 0) for d in data], dtype=float)

    # Phase map: first occurrence time (ms) for each phase label
    phase_map = {}
    for d, t in zip(data, times):
        phase = d.get('phase', '')
        if phase and phase not in phase_map:
            phase_map[phase] = t

    return times, rss, gc, heap, phase_map


def aggregate_monitor_files(file_list):
    """Aggregate multiple monitor CSVs into a single averaged time series.

    Returns list of dicts matching parse_continuous_monitor_data format but averaged.
    """
    runs = []
    for f in file_list:
        times, rss, gc, heap, phase_map = load_monitor_file(f)
        if times is None:
            continue
        runs.append({'times': times, 'rss': rss, 'gc': gc, 'heap': heap, 'phase_map': phase_map})

    if not runs:
        return []

    # Determine common end time (ms)
    end_times = [r['times'][-1] for r in runs]
    common_end = min(end_times)

    # Estimate dt as median of median diffs across runs (ms)
    dts = []
    for r in runs:
        diffs = np.diff(r['times'])
        if len(diffs):
            dts.append(np.median(diffs))
    if dts:
        dt = float(np.median(dts))
    else:
        dt = 500.0
    if dt <= 0:
        dt = 500.0

    grid = np.arange(0, common_end + 1e-6, dt)

    rss_interp = []
    gc_interp = []
    heap_interp = []
    phase_times = {}
    for r in runs:
        rss_i = np.interp(grid, r['times'], r['rss'])
        gc_i = np.interp(grid, r['times'], r['gc'])
        heap_i = np.interp(grid, r['times'], r['heap'])
        rss_interp.append(rss_i)
        gc_interp.append(gc_i)
        heap_interp.append(heap_i)
        for phase, t in r['phase_map'].items():
            phase_times.setdefault(phase, []).append(t)

    rss_stack = np.vstack(rss_interp)
    gc_stack = np.vstack(gc_interp)
    heap_stack = np.vstack(heap_interp)

    rss_mean = np.mean(rss_stack, axis=0)
    rss_std = np.std(rss_stack, axis=0)
    gc_mean = np.mean(gc_stack, axis=0)
    gc_std = np.std(gc_stack, axis=0)
    heap_mean = np.mean(heap_stack, axis=0)
    heap_std = np.std(heap_stack, axis=0)

    # Average phase times across runs that had them
    phase_marks = []
    for phase, times_list in phase_times.items():
        avg_t = float(np.mean(times_list)) / 1000.0  # convert to seconds for plotting convenience
        phase_marks.append((avg_t, phase))

    # Build aggregated list of dicts similar to parse output, but with averaged numeric values
    agg = []
    for i, t in enumerate(grid):
        entry = {
            'timestamp_ms': int(t),
            'rss_kb': int(rss_mean[i]),
            'gc_committed_kb': int(gc_mean[i]),
            'heap_kb': int(heap_mean[i]),
            'rss_std_kb': float(rss_std[i]),
            'gc_std_kb': float(gc_std[i]),
            'heap_std_kb': float(heap_std[i]),
            'phase': ''
        }
        agg.append(entry)

    # Insert phase labels into nearest grid point (by time in seconds)
    for avg_t, phase in phase_marks:
        # avg_t in seconds -> convert to ms
        target_ms = avg_t * 1000.0
        idx = int(np.argmin(np.abs(grid - target_ms)))
        agg[idx]['phase'] = phase

    return agg


def extract_phases_from_monitor_file(filename):
    """Extract all unique phases from a monitor file with iteration info.
    
    Returns: dict (phase_name, iteration) -> first_occurrence_time_ms
    """
    phases = {}
    data = parse_continuous_monitor_data(filename)
    for entry in data:
        phase = entry.get('phase', '')
        iteration = entry.get('iteration', '')
        if phase:
            key = (phase, iteration)
            if key not in phases:
                phases[key] = entry['timestamp_ms']
    return phases


def extract_phases_with_iteration(data_list):
    """Extract phases with their iteration numbers from data.
    
    Uses actual iteration data from CSV if available, otherwise detects by Phase 1 occurrences.
    Returns: list of (time_sec, phase_name_with_iter) tuples
    """
    if not data_list:
        return []
    
    phase_marks = []
    last_phase = ""
    last_iteration = ""
    base_time = data_list[0]['timestamp_ms']
    
    for d in data_list:
        phase = d.get('phase', '')
        iteration = d.get('iteration', '')
        
        # Skip empty phases
        if not phase:
            continue
        
        # Skip phase transitions with empty iterations (orphan phases at end of run)
        if not iteration:
            continue
            
        # Only add phase marks on phase transitions
        if phase != last_phase or iteration != last_iteration:
            t = (d['timestamp_ms'] - base_time) / 1000.0
            
            # Build phase label with iteration (always present due to filter above)
            phase_with_iter = f"{phase} [{iteration}]"
            
            phase_marks.append((t, phase_with_iter, phase))
            last_phase = phase
            last_iteration = iteration
    
    return phase_marks


def plot_continuous_monitoring(on_data, off_data, on_monitor_files=None, off_monitor_files=None, run_id=1, output_file=None):
    """Plot continuous memory monitoring data over time."""
    
    if output_file is None:
        output_file = f'images/continuous_memory_{run_id}.png'
    
    # Ensure output directory exists
    Path('output').mkdir(parents=True, exist_ok=True)
    
    if not on_data and not off_data:
        print("No continuous monitoring data to plot")
        return
    
    # Create figure with three subplots (RSS, GC aux, Java heap)
    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(14, 12), sharex=True)
    
    # Initialize phase marks - now includes iteration info and original phase
    on_phase_marks = []
    off_phase_marks = []
    
    # Extract phases with iteration numbers from aggregated data
    if on_data:
        on_phase_marks_raw = extract_phases_with_iteration(on_data)
        # Convert from (t, label_with_iter, original_phase) to (t, label_with_iter) for drawing
        on_phase_marks = [(t, label) for t, label, _ in on_phase_marks_raw]
    
    if off_data:
        off_phase_marks_raw = extract_phases_with_iteration(off_data)
        off_phase_marks = [(t, label) for t, label, _ in off_phase_marks_raw]
    
    # Always supplement with ALL phases from monitor files to ensure we capture all iteration phases
    if on_monitor_files and on_data:
        on_phases_from_files = {}  # (phase_name, iteration_str) -> [relative_time_ms, relative_time_ms, ...]
        for f in on_monitor_files:
            # Get first timestamp from this run to normalize relative times
            run_data = parse_continuous_monitor_data(f)
            if not run_data:
                continue
            run_start_time = run_data[0]['timestamp_ms']
            
            # Extract phases and convert to relative time within this run
            phases = extract_phases_from_monitor_file(f)
            for (phase_name, iteration_str), abs_time_ms in phases.items():
                # Skip entries with empty iteration strings (orphan phases at end of run)
                if not iteration_str:
                    continue
                relative_time_ms = abs_time_ms - run_start_time  # Relative to this run's start
                key = (phase_name, iteration_str)
                if key not in on_phases_from_files:
                    on_phases_from_files[key] = []
                on_phases_from_files[key].append(relative_time_ms)
        
        # Create phase marks from monitor file data (averaged relative times)
        for (phase_name, iteration_str), time_list in sorted(on_phases_from_files.items()):
            # Average relative times across all on runs
            avg_relative_time_ms = np.mean(time_list)
            time_sec = avg_relative_time_ms / 1000.0
            
            # Build label
            if iteration_str:
                phase_label = f"{phase_name} [{iteration_str}]"
            else:
                phase_label = phase_name
            
            # Add this phase (replace aggregated if exists)
            on_phase_marks = [(t, l) for t, l in on_phase_marks if l != phase_label]
            if time_sec >= 0:
                on_phase_marks.append((time_sec, phase_label))
        
        # Sort by time
        on_phase_marks.sort(key=lambda x: x[0])
    
    if off_monitor_files and off_data:
        off_phases_from_files = {}  # (phase_name, iteration_str) -> [relative_time_ms, relative_time_ms, ...]
        for f in off_monitor_files:
            # Get first timestamp from this run to normalize relative times
            run_data = parse_continuous_monitor_data(f)
            if not run_data:
                continue
            run_start_time = run_data[0]['timestamp_ms']
            
            # Extract phases and convert to relative time within this run
            phases = extract_phases_from_monitor_file(f)
            for (phase_name, iteration_str), abs_time_ms in phases.items():
                # Skip entries with empty iteration strings (orphan phases at end of run)
                if not iteration_str:
                    continue
                relative_time_ms = abs_time_ms - run_start_time  # Relative to this run's start
                key = (phase_name, iteration_str)
                if key not in off_phases_from_files:
                    off_phases_from_files[key] = []
                off_phases_from_files[key].append(relative_time_ms)
        
        # Create phase marks from monitor file data (averaged relative times)
        for (phase_name, iteration_str), time_list in sorted(off_phases_from_files.items()):
            # Average relative times across all off runs
            avg_relative_time_ms = np.mean(time_list)
            time_sec = avg_relative_time_ms / 1000.0
            
            # Build label
            if iteration_str:
                phase_label = f"{phase_name} [{iteration_str}]"
            else:
                phase_label = phase_name
            
            # Add this phase (replace aggregated if exists)
            off_phase_marks = [(t, l) for t, l in off_phase_marks if l != phase_label]
            if time_sec >= 0:
                off_phase_marks.append((time_sec, phase_label))
        
        # Sort by time
        off_phase_marks.sort(key=lambda x: x[0])
    
    # Plot RSS (Total Process Memory)
    if on_data:
        on_times = [(d['timestamp_ms'] - on_data[0]['timestamp_ms']) / 1000.0 for d in on_data]  # seconds
        on_rss = [d['rss_kb'] / 1024.0 for d in on_data]  # MB
        on_rss_std = [d.get('rss_std_kb', 0) / 1024.0 for d in on_data]  # MB
        ax1.plot(on_times, on_rss, '-', linewidth=1.5, label='GA ON', color='blue', alpha=0.7)
        ax1.fill_between(on_times, 
                        [r - s for r, s in zip(on_rss, on_rss_std)],
                        [r + s for r, s in zip(on_rss, on_rss_std)],
                        color='blue', alpha=0.2, linewidth=0)
    
    if off_data:
        off_times = [(d['timestamp_ms'] - off_data[0]['timestamp_ms']) / 1000.0 for d in off_data]  # seconds
        off_rss = [d['rss_kb'] / 1024.0 for d in off_data]  # MB
        off_rss_std = [d.get('rss_std_kb', 0) / 1024.0 for d in off_data]  # MB
        ax1.plot(off_times, off_rss, '-', linewidth=1.5, label='GA OFF', color='red', alpha=0.7)
        ax1.fill_between(off_times,
                        [r - s for r, s in zip(off_rss, off_rss_std)],
                        [r + s for r, s in zip(off_rss, off_rss_std)],
                        color='red', alpha=0.2, linewidth=0)
    
    ax1.set_ylabel('Total Process RSS (MB)', fontsize=12)
    ax1.set_title('Continuous Total Process Memory Usage (Mean ± Std Dev)', fontsize=14, fontweight='bold')
    ax1.legend(fontsize=11)
    ax1.grid(True, alpha=0.3)
    
    # Plot GC Auxiliary Memory (Committed)
    if on_data:
        on_gc = [d['gc_committed_kb'] / 1024.0 for d in on_data]  # MB
        on_gc_std = [d.get('gc_std_kb', 0) / 1024.0 for d in on_data]  # MB
        ax2.plot(on_times, on_gc, '-', linewidth=1.5, label='GA ON', color='blue', alpha=0.7)
        ax2.fill_between(on_times,
                        [g - s for g, s in zip(on_gc, on_gc_std)],
                        [g + s for g, s in zip(on_gc, on_gc_std)],
                        color='blue', alpha=0.2, linewidth=0)
    
    if off_data:
        off_gc = [d['gc_committed_kb'] / 1024.0 for d in off_data]
        off_gc_std = [d.get('gc_std_kb', 0) / 1024.0 for d in off_data]  # MB
        ax2.plot(off_times, off_gc, '-', linewidth=1.5, label='GA OFF', color='red', alpha=0.7)
        ax2.fill_between(off_times,
                        [g - s for g, s in zip(off_gc, off_gc_std)],
                        [g + s for g, s in zip(off_gc, off_gc_std)],
                        color='red', alpha=0.2, linewidth=0)
    
    ax2.set_ylabel('GC Auxiliary Memory (MB)', fontsize=12)
    ax2.set_title('Continuous GC Auxiliary Memory Usage (Mean ± Std Dev)', fontsize=14, fontweight='bold')
    ax2.legend(fontsize=11)
    ax2.grid(True, alpha=0.3)

    # Plot Java heap usage
    if on_data:
        on_heap = [d['heap_kb'] / 1024.0 for d in on_data]
        on_heap_std = [d.get('heap_std_kb', 0) / 1024.0 for d in on_data]  # MB
        ax3.plot(on_times, on_heap, '-', linewidth=1.5, label='GA ON', color='blue', alpha=0.7)
        ax3.fill_between(on_times,
                        [h - s for h, s in zip(on_heap, on_heap_std)],
                        [h + s for h, s in zip(on_heap, on_heap_std)],
                        color='blue', alpha=0.2, linewidth=0)

    if off_data:
        off_heap = [d['heap_kb'] / 1024.0 for d in off_data]
        off_heap_std = [d.get('heap_std_kb', 0) / 1024.0 for d in off_data]  # MB
        ax3.plot(off_times, off_heap, '-', linewidth=1.5, label='GA OFF', color='red', alpha=0.7)
        ax3.fill_between(off_times,
                        [h - s for h, s in zip(off_heap, off_heap_std)],
                        [h + s for h, s in zip(off_heap, off_heap_std)],
                        color='red', alpha=0.2, linewidth=0)
        
    ax3.set_xlabel('Time (seconds)', fontsize=12)
    ax3.set_ylabel('Java Heap (MB)', fontsize=12)
    ax3.set_title('Java Heap Usage (Mean ± Std Dev, from jcmd GC.heap_info)', fontsize=14, fontweight='bold')
    ax3.legend(fontsize=11)
    ax3.grid(True, alpha=0.3)
    
    # Draw phase markers and shade phase spans (vertical lines + labels + shaded regions)
    def draw_phase_marks(ax, marks, color):
        if not marks:
            return
        ylim = ax.get_ylim()
        y_text = ylim[1] * 0.95
        for t, label in marks:
            ax.axvline(x=t, color=color, linestyle='--', alpha=0.3)
            ax.text(t, y_text, label, rotation=90, va='top', ha='center', fontsize=7, color=color, alpha=0.8)

    # Shade phase spans on all subplots - shade variance in same phase/iteration across runs
    def shade_phase_spans_by_mode(axes_list, on_marks, off_marks, on_phase_times, off_phase_times):
        # For ON phases: shade between min and max occurrence times for each phase+iteration
        for (phase_name, iteration_str), time_list in on_phase_times.items():
            if time_list:
                t_min = min(time_list)
                t_max = max(time_list)
                if t_min < t_max:  # Only shade if there's actually variance
                    for ax in axes_list:
                        ax.axvspan(t_min, t_max, alpha=0.06, color='blue')
        
        # For OFF phases: shade between min and max occurrence times for each phase+iteration
        for (phase_name, iteration_str), time_list in off_phase_times.items():
            if time_list:
                t_min = min(time_list)
                t_max = max(time_list)
                if t_min < t_max:  # Only shade if there's actually variance
                    for ax in axes_list:
                        ax.axvspan(t_min, t_max, alpha=0.06, color='red')
    
    # Convert phase times from ms to seconds for shading
    on_phase_times_sec = {key: [t_ms / 1000.0 for t_ms in times] for key, times in on_phases_from_files.items()} if 'on_phases_from_files' in locals() and on_phases_from_files else {}
    off_phase_times_sec = {key: [t_ms / 1000.0 for t_ms in times] for key, times in off_phases_from_files.items()} if 'off_phases_from_files' in locals() and off_phases_from_files else {}
    shade_phase_spans_by_mode([ax1, ax2, ax3], 
                              on_phase_marks if on_data else [], 
                              off_phase_marks if off_data else [],
                              on_phase_times_sec,
                              off_phase_times_sec)
    
    draw_phase_marks(ax1, on_phase_marks if on_data else [], 'blue')
    draw_phase_marks(ax2, on_phase_marks if on_data else [], 'blue')
    draw_phase_marks(ax3, on_phase_marks if on_data else [], 'blue')
    draw_phase_marks(ax1, off_phase_marks if off_data else [], 'red')
    draw_phase_marks(ax2, off_phase_marks if off_data else [], 'red')
    draw_phase_marks(ax3, off_phase_marks if off_data else [], 'red')
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Continuous monitoring plot saved to: {output_file}")


def parse_gc_stats_file(filename):
    """Parse a run log file and extract GC metrics with their Total Avg/Max values and units."""
    metrics = {}
    
    if not Path(filename).exists():
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
            
            # Extract units from the end of the line
            units_match = re.search(r'(\d+\.?\d*)\s*/\s*(\d+\.?\d*)\s+(\S+)\s*$', data)
            units = ""
            if units_match:
                units = units_match.group(3)
            
            if metric_name:
                if metric_name not in metrics:
                    metrics[metric_name] = {"avg": [], "max": [], "units": units}
                metrics[metric_name]["avg"].append(total_avg)
                metrics[metric_name]["max"].append(total_max)
    
    return metrics


def aggregate_gc_metrics(file_list):
    """Aggregate GC metrics across multiple run log files (all runs pooled).
    
    Returns dict: metric_name -> {'avg': avg_value, 'max': avg_value, 'avg_std': std_value, 'max_std': std_value, 'units': str}
    """
    all_metrics = {}
    
    for f in file_list:
        metrics = parse_gc_stats_file(f)
        for metric_name, data in metrics.items():
            if metric_name not in all_metrics:
                all_metrics[metric_name] = {"avg": [], "max": [], "units": data["units"]}
            all_metrics[metric_name]["avg"].extend(data["avg"])
            all_metrics[metric_name]["max"].extend(data["max"])
    
    # Compute averages and standard deviations across all samples (all runs pooled)
    agg = {}
    for metric_name, data in all_metrics.items():
        agg[metric_name] = {
            "avg": float(np.mean(data["avg"])) if data["avg"] else 0.0,
            "max": float(np.mean(data["max"])) if data["max"] else 0.0,
            "avg_std": float(np.std(data["avg"])) if len(data["avg"]) > 1 else 0.0,
            "max_std": float(np.std(data["max"])) if len(data["max"]) > 1 else 0.0,
            "units": data["units"]
        }
    
    return agg


def main():
    # Parse command line arguments
    run_id = 1  # Default ID
    if len(sys.argv) > 1:
        if sys.argv[1] == "--id" and len(sys.argv) > 2:
            run_id = sys.argv[2]
        elif sys.argv[1].startswith("--id="):
            run_id = sys.argv[1].split("=")[1]
    
    # Find all monitor and log files for ON/OFF with the specified ID
    on_monitor_files = sorted(glob.glob(f"output/monitor_ON_*_{run_id}.csv"))
    off_monitor_files = sorted(glob.glob(f"output/monitor_OFF_*_{run_id}.csv"))
    on_log_files = sorted(glob.glob(f"output/run_ON_*_{run_id}.log"))
    off_log_files = sorted(glob.glob(f"output/run_OFF_*_{run_id}.log"))
    
    if not on_monitor_files or not off_monitor_files or not on_log_files or not off_log_files:
        print("Error: Could not find all required output files")
        print(f"  output/monitor_ON_*_{run_id}.csv, output/monitor_OFF_*_{run_id}.csv")
        print(f"  output/run_ON_*_{run_id}.log, output/run_OFF_*_{run_id}.log")
        print("\nMake sure you have run the benchmark script first:")
        print(f"  sudo -E bash run_benchmark_iterations.sh [--id {run_id}]")
        return 1
    
    # Extract run numbers to validate consistency
    on_runs_raw = [extract_run_num(f) for f in on_monitor_files]
    off_runs_raw = [extract_run_num(f) for f in off_monitor_files]
    
    on_runs = sorted([i for i in on_runs_raw if i is not None])
    off_runs = sorted([i for i in off_runs_raw if i is not None])
    
    print("\n" + "=" * 100)
    print(" " * 35 + "BENCHMARK ANALYSIS REPORT")
    print("=" * 100 + "\n")
    
    # Display run information
    print(f"GA ON  - Found {len(on_monitor_files)} monitor files and {len(on_log_files)} log files from runs: {on_runs}")
    print(f"GA OFF - Found {len(off_monitor_files)} monitor files and {len(off_log_files)} log files from runs: {off_runs}")
    
    # Check consistency
    if on_runs != off_runs:
        print(f"\n⚠ Warning: Runs don't match!")
        print(f"  ON runs:  {on_runs}")
        print(f"  OFF runs: {off_runs}")
    else:
        print(f"✓ Runs match: {on_runs}")
    
    print()
    
    # Parse and aggregate GC metrics from all run logs (across all runs)
    print("Parsing and aggregating GC metrics from all runs...")
    on_gc_agg = aggregate_gc_metrics(on_log_files)
    off_gc_agg = aggregate_gc_metrics(off_log_files)
    print(f"  Found {len(on_gc_agg)} metrics in ON runs")
    print(f"  Found {len(off_gc_agg)} metrics in OFF runs")
    
    # Display GC metrics comparison table
    if on_gc_agg or off_gc_agg:
        print("\n" + "-" * 170)
        print(" " * 50 + "GC METRICS COMPARISON (Averages ± Std Dev over all runs)")
        print("-" * 170)
        
        header = f"{'Metric':<50} {'Unit':>8} {'ON Avg':>18} {'ON Max':>18} {'OFF Avg':>18} {'OFF Max':>18} {'AvgDiff%':>12} {'MaxDiff%':>12}"
        print(header)
        print("-" * 170)
        
        # Get all unique metric names, sorted
        all_metrics = sorted(set(on_gc_agg.keys()) | set(off_gc_agg.keys()))
        
        for metric in all_metrics:
            on_avg = on_gc_agg.get(metric, {}).get("avg", None)
            on_max = on_gc_agg.get(metric, {}).get("max", None)
            on_avg_std = on_gc_agg.get(metric, {}).get("avg_std", None)
            on_max_std = on_gc_agg.get(metric, {}).get("max_std", None)
            off_avg = off_gc_agg.get(metric, {}).get("avg", None)
            off_max = off_gc_agg.get(metric, {}).get("max", None)
            off_avg_std = off_gc_agg.get(metric, {}).get("avg_std", None)
            off_max_std = off_gc_agg.get(metric, {}).get("max_std", None)
            
            # Format with ± std dev
            on_avg_str = f"{on_avg:.2f}±{on_avg_std:.2f}" if on_avg is not None and on_avg_std is not None else "n/a"
            on_max_str = f"{on_max:.2f}±{on_max_std:.2f}" if on_max is not None and on_max_std is not None else "n/a"
            off_avg_str = f"{off_avg:.2f}±{off_avg_std:.2f}" if off_avg is not None and off_avg_std is not None else "n/a"
            off_max_str = f"{off_max:.2f}±{off_max_std:.2f}" if off_max is not None and off_max_std is not None else "n/a"
            
            # Get units
            units = on_gc_agg.get(metric, {}).get("units", "")
            if not units:
                units = off_gc_agg.get(metric, {}).get("units", "")
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
            
            row = f"{metric_display:<50} {units_str:>8} {on_avg_str:>18} {on_max_str:>18} {off_avg_str:>18} {off_max_str:>18} {avg_diff_str:>12} {max_diff_str:>12}"
            print(row)
        
        print("-" * 170)
        print()
    
    # Parse continuous monitoring data and aggregate across outer runs
    print("Aggregating continuous monitoring data...")
    on_continuous = []
    off_continuous = []
    
    if on_monitor_files:
        on_continuous = aggregate_monitor_files(on_monitor_files)
        print(f"  ON:  Aggregated {len(on_continuous)} continuous samples")
    
    if off_monitor_files:
        off_continuous = aggregate_monitor_files(off_monitor_files)
        print(f"  OFF: Aggregated {len(off_continuous)} continuous samples")
    
    # Debug: Show what phases are in each monitor file
    print("\nPhase information from monitor files:")
    for f in on_monitor_files:
        phases = extract_phases_from_monitor_file(f)
        # Filter out empty iterations to match what's actually plotted
        phases = {k: v for k, v in phases.items() if k[1]}  # k = (phase, iteration)
        run_num = extract_run_num(f)
        if phases:
            phase_strs = [f"{phase} [{iter_str}]" for phase, iter_str in sorted(phases.keys())]
            print(f"  ON run{run_num}: {', '.join(phase_strs)}")
        else:
            print(f"  ON run{run_num}: (no phases)")
    for f in off_monitor_files:
        phases = extract_phases_from_monitor_file(f)
        # Filter out empty iterations to match what's actually plotted
        phases = {k: v for k, v in phases.items() if k[1]}  # k = (phase, iteration)
        run_num = extract_run_num(f)
        if phases:
            phase_strs = [f"{phase} [{iter_str}]" for phase, iter_str in sorted(phases.keys())]
            print(f"  OFF run{run_num}: {', '.join(phase_strs)}")
        else:
            print(f"  OFF run{run_num}: (no phases)")
    
    # Plot continuous monitoring data if available
    if on_continuous or off_continuous:
        print("\nGenerating continuous monitoring plot...")
        plot_continuous_monitoring(on_continuous, off_continuous, on_monitor_files, off_monitor_files, run_id)
        print("✓ Plot generated successfully!")
    else:
        print("Warning: No continuous monitoring data to plot")
        return 1
    
    print("\n" + "=" * 100)
    print()
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
