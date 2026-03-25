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


def get_benchmark_mode_label(benchmark_name):
    """Return canonical benchmark mode label used in plot names and titles."""
    single_modes = {"single", "field-single", "single-field"}
    return "single" if benchmark_name in single_modes else "double"


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


def plot_metric_boxplots(variants_all_metrics, variants, metric_names, run_id=1, benchmark_mode_label="double"):
    """Plot boxplots comparing all variant configs for each metric.

    Each metric gets its own subplot. Within each subplot there is one box per
    variant config so distributions across the full set of runs can be compared
    at a glance.
    """
    Path('images').mkdir(parents=True, exist_ok=True)

    DISPLAY_NAMES = {
        "none": "Baseline",
        "all": "All",
        "clear_path_only": "Clear Path",
        "sep_only": "Sep",
        "dyn_only": "Dyn",
        "clear_path_sep": "Clear Path\n+Sep",
        "clear_path_dyn": "Clear Path\n+Dyn",
        "sep_dyn": "Sep+Dyn",
        "weak_fields": "Weak Fields",
    }

    # Keep only metrics that have data in at least one variant
    metrics_to_plot = [
        m for m in metric_names
        if any(m in variants_all_metrics.get(v, {}) for v in variants)
    ]

    if not metrics_to_plot:
        print("Warning: none of the requested metrics found in data")
        return

    n_metrics = len(metrics_to_plot)
    n_cols = min(3, n_metrics)
    n_rows = (n_metrics + n_cols - 1) // n_cols

    fig, axes = plt.subplots(n_rows, n_cols, figsize=(6 * n_cols, 5 * n_rows))
    if n_rows == 1 and n_cols == 1:
        axes = np.array([[axes]])
    elif n_rows == 1:
        axes = axes.reshape(1, -1)
    elif n_cols == 1:
        axes = axes.reshape(-1, 1)

    # Distinct colours for up to 9 variants
    colors = [plt.cm.tab10(i / max(len(variants) - 1, 1)) for i in range(len(variants))]

    for idx, metric_name in enumerate(metrics_to_plot):
        row = idx // n_cols
        col = idx % n_cols
        ax = axes[row, col]

        data_per_variant = []
        labels = []
        for variant in variants:
            values = variants_all_metrics.get(variant, {}).get(metric_name, {}).get("avg", [])
            data_per_variant.append(values if values else [])
            labels.append(DISPLAY_NAMES.get(variant, variant))

        # Remove variants with no data so the plot is not cluttered with empty boxes
        non_empty = [(d, l, c) for d, l, c in zip(data_per_variant, labels, colors) if d]
        if not non_empty:
            ax.text(0.5, 0.5, 'No data', ha='center', va='center', transform=ax.transAxes)
            ax.set_title(metric_name[:55], fontsize=10, fontweight='bold')
            continue
        data_filtered, labels_filtered, colors_filtered = zip(*non_empty)

        bp = ax.boxplot(data_filtered, labels=labels_filtered, patch_artist=True, notch=False)
        for patch, color in zip(bp['boxes'], colors_filtered):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)

        units = next(
            (variants_all_metrics.get(v, {}).get(metric_name, {}).get("units", "")
             for v in variants
             if variants_all_metrics.get(v, {}).get(metric_name, {}).get("units")),
            ""
        )

        ax.set_title(metric_name[:55], fontsize=10, fontweight='bold')
        ax.set_ylabel(f"Value ({units})" if units else "Value", fontsize=9)
        ax.tick_params(axis='x', labelsize=8, rotation=15)
        ax.grid(True, alpha=0.3, axis='y')

    # Add sample-count annotation to the last used subplot
    for idx in range(n_metrics, n_rows * n_cols):
        axes[idx // n_cols][idx % n_cols].axis('off')

    plt.suptitle(
        f"GC Metrics Comparison Across Configurations ({benchmark_mode_label.capitalize()} Benchmark)",
        fontsize=14,
        fontweight='bold',
    )
    plt.tight_layout()
    output_file = f'images/metric_boxplots_{benchmark_mode_label}_{run_id}.pdf'
    plt.savefig(output_file, bbox_inches='tight')
    print(f"Metric boxplots saved to: {output_file}")
    plt.close()


def plot_continuous_monitoring(on_data, off_data, on_monitor_files=None, off_monitor_files=None,
                               run_id=1, output_file=None, benchmark_mode_label="double"):
    """Plot continuous memory monitoring data over time."""
    
    if output_file is None:
        output_file = f'images/continuous_memory_{benchmark_mode_label}_{run_id}.pdf'
    
    # Ensure images directory exists
    Path('images').mkdir(parents=True, exist_ok=True)
    
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
    # on_phase_times_sec = {key: [t_ms / 1000.0 for t_ms in times] for key, times in on_phases_from_files.items()} if 'on_phases_from_files' in locals() and on_phases_from_files else {}
    # off_phase_times_sec = {key: [t_ms / 1000.0 for t_ms in times] for key, times in off_phases_from_files.items()} if 'off_phases_from_files' in locals() and off_phases_from_files else {}
    # shade_phase_spans_by_mode([ax1, ax2, ax3], 
    #                           on_phase_marks if on_data else [], 
    #                           off_phase_marks if off_data else [],
    #                           on_phase_times_sec,
    #                           off_phase_times_sec)
    
    # draw_phase_marks(ax1, on_phase_marks if on_data else [], 'blue')
    # draw_phase_marks(ax2, on_phase_marks if on_data else [], 'blue')
    # draw_phase_marks(ax3, on_phase_marks if on_data else [], 'blue')
    # draw_phase_marks(ax1, off_phase_marks if off_data else [], 'red')
    # draw_phase_marks(ax2, off_phase_marks if off_data else [], 'red')
    # draw_phase_marks(ax3, off_phase_marks if off_data else [], 'red')
    
    fig.suptitle(
        f"Continuous Memory Usage ({benchmark_mode_label.capitalize()} Benchmark)",
        fontsize=15,
        fontweight='bold',
        y=1.01,
    )
    plt.tight_layout(rect=[0, 0, 1, 0.98])
    plt.savefig(output_file, bbox_inches='tight')
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
    
    Returns two dicts:
    1. all_metrics: metric_name -> {'avg': [list of values], 'max': [list of values], 'units': str}
    2. agg: metric_name -> {'avg': avg_value, 'max': avg_value, 'avg_std': std_value, 'max_std': std_value, 'units': str}
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
    
    return all_metrics, agg


def plot_continuous_monitoring_multi(variants_continuous, run_id=1, benchmark_mode_label="double"):
    """Plot mean RSS, GC-auxiliary, and heap usage over time for N variant configs.

    Each variant is drawn as a distinct colour. Shaded bands show ±1 std dev.
    """
    Path('images').mkdir(parents=True, exist_ok=True)

    DISPLAY_NAMES = {
        "none": "Baseline",
        "all": "All",
        "clear_path_only": "Optimised Clear Path",
        "sep_only": "Sep",
        "dyn_only": "Dyn",
        "clear_path_sep": "Optimised Clear Path+Sep",
        "clear_path_dyn": "Optimised Clear Path+Dyn",
        "sep_dyn": "Sep+Dyn",
        "weak_fields": "Weak Fields",
    }

    if not variants_continuous:
        print("No continuous monitoring data to plot")
        return

    variant_list = list(variants_continuous.keys())
    colors = [plt.cm.tab10(i / max(len(variant_list) - 1, 1)) for i in range(len(variant_list))]

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(14, 12), sharex=True)

    for variant, color in zip(variant_list, colors):
        data = variants_continuous[variant]
        if not data:
            continue
        label = DISPLAY_NAMES.get(variant, variant)
        times = [(d['timestamp_ms'] - data[0]['timestamp_ms']) / 1000.0 for d in data]
        rss   = [d['rss_kb'] / 1024.0 for d in data]
        rss_s = [d.get('rss_std_kb', 0) / 1024.0 for d in data]
        gc    = [d['gc_committed_kb'] / 1024.0 for d in data]
        gc_s  = [d.get('gc_std_kb', 0) / 1024.0 for d in data]
        heap  = [d.get('heap_kb', 0) / 1024.0 for d in data]
        heap_s = [d.get('heap_std_kb', 0) / 1024.0 for d in data]

        ax1.plot(times, rss, linewidth=1.5, label=label, color=color, alpha=0.85)
        ax1.fill_between(times, [r - s for r, s in zip(rss, rss_s)],
                         [r + s for r, s in zip(rss, rss_s)], color=color, alpha=0.15, linewidth=0)

        ax2.plot(times, gc, linewidth=1.5, label=label, color=color, alpha=0.85)
        ax2.fill_between(times, [g - s for g, s in zip(gc, gc_s)],
                         [g + s for g, s in zip(gc, gc_s)], color=color, alpha=0.15, linewidth=0)

        ax3.plot(times, heap, linewidth=1.5, label=label, color=color, alpha=0.85)
        ax3.fill_between(times, [h - s for h, s in zip(heap, heap_s)],
                         [h + s for h, s in zip(heap, heap_s)], color=color, alpha=0.15, linewidth=0)

    ax1.set_ylabel('Total Process RSS (MB)', fontsize=12)
    ax1.set_title('Total Process Memory (Mean \u00b1 Std Dev)', fontsize=13, fontweight='bold')
    ax1.legend(fontsize=10)
    ax1.grid(True, alpha=0.3)

    ax2.set_ylabel('GC Auxiliary Memory (MB)', fontsize=12)
    ax2.set_title('GC Auxiliary Memory (Mean \u00b1 Std Dev)', fontsize=13, fontweight='bold')
    ax2.legend(fontsize=10)
    ax2.grid(True, alpha=0.3)

    ax3.set_xlabel('Time (seconds)', fontsize=12)
    ax3.set_ylabel('Java Heap (MB)', fontsize=12)
    ax3.set_title('Java Heap Usage (Mean \u00b1 Std Dev)', fontsize=13, fontweight='bold')
    ax3.legend(fontsize=10)
    ax3.grid(True, alpha=0.3)

    fig.suptitle(
        f"Continuous Memory Usage ({benchmark_mode_label.capitalize()} Benchmark)",
        fontsize=15,
        fontweight='bold',
        y=1.01,
    )
    plt.tight_layout(rect=[0, 0, 1, 0.98])
    output_file = f'images/continuous_memory_{benchmark_mode_label}_{run_id}.pdf'
    plt.savefig(output_file, bbox_inches='tight')
    print(f"Continuous monitoring plot saved to: {output_file}")
    plt.close()


def main():
    # Parse command line arguments
    run_id = 1
    if len(sys.argv) > 1:
        if sys.argv[1] == "--id" and len(sys.argv) > 2:
            run_id = sys.argv[2]
        elif sys.argv[1].startswith("--id="):
            run_id = sys.argv[1].split("=")[1]

    # Auto-detect benchmark name from output files for this run_id.
    # When weak-fields is enabled, this run id can contain both gc/single logs
    # and field/field-single logs. Pick the dominant benchmark family.
    candidate_files = glob.glob(f"output/run_*_*_run*_{run_id}.log")
    benchmark_name = "gc"  # default
    if candidate_files:
        benchmark_counts = {
            "gc": 0,
            "weakref": 0,
            "single": 0,
            "field": 0,
            "field-single": 0,
            "single-field": 0,
        }
        benchmark_tokens = [
            "field-single",
            "single-field",
            "weakref",
            "single",
            "field",
            "gc",
        ]
        for f in candidate_files:
            base = Path(f).name
            for token in benchmark_tokens:
                if base.startswith(f"run_{token}_"):
                    benchmark_counts[token] += 1
                    break

        benchmark_priority = ["gc", "single", "weakref", "field", "field-single", "single-field"]
        benchmark_name = max(benchmark_priority, key=lambda b: (benchmark_counts[b], -benchmark_priority.index(b)))
    use_max = benchmark_name == "single"
    benchmark_mode_label = get_benchmark_mode_label(benchmark_name)

    weak_fields_benchmark_name = None
    if benchmark_name in ["gc", "weakref", "field", "weakfield"]:
        weak_fields_benchmark_name = "field"
    elif benchmark_name in ["single", "field-single", "single-field"]:
        weak_fields_benchmark_name = "field-single"

    # Canonical variant order (matches scripts/run_benchmark_iterations.sh)
    VARIANTS_ORDERED = [
        "none", "clear_path_only", "sep_only", "dyn_only",
        "clear_path_sep", "clear_path_dyn", "sep_dyn", "all", "weak_fields",
    ]

    # Discover which variants actually produced output files for this run_id.
    # weak_fields has existed with two naming schemes:
    # 1) output/run_field(_single)_weak_fields_...
    # 2) output/run_<benchmark_name>_weak_fields_...
    variants_log_files = {}
    variants_monitor_files = {}
    for variant in VARIANTS_ORDERED:
        if variant == "weak_fields":
            source_benchmarks = [benchmark_name]
            if weak_fields_benchmark_name:
                source_benchmarks.append(weak_fields_benchmark_name)
            # De-duplicate while preserving order
            source_benchmarks = list(dict.fromkeys(source_benchmarks))
        else:
            source_benchmarks = [benchmark_name]

        log_files = []
        monitor_files = []
        for source_benchmark in source_benchmarks:
            log_files.extend(glob.glob(f"output/run_{source_benchmark}_{variant}_*_{run_id}.log"))
            monitor_files.extend(glob.glob(f"output/monitor_{source_benchmark}_{variant}_*_{run_id}.csv"))
        log_files = sorted(set(log_files))
        monitor_files = sorted(set(monitor_files))
        if log_files:
            variants_log_files[variant] = log_files
        if monitor_files:
            variants_monitor_files[variant] = monitor_files

    if not variants_log_files:
        print(f"Error: no log files found in output/ for run id '{run_id}'")
        print("Make sure you have run:")
        print("  sudo -E bash scripts/run_benchmark_iterations.sh")
        return 1

    present = [v for v in VARIANTS_ORDERED if v in variants_log_files]

    print("\n" + "=" * 80)
    print(f"{'BENCHMARK ANALYSIS REPORT':^80}")
    print("=" * 80 + "\n")
    print(f"Run ID    : {run_id}")
    print(f"Benchmark : {benchmark_name}{'  (using max values)' if use_max else ''}")
    print(f"Mode      : {benchmark_mode_label}")
    if weak_fields_benchmark_name:
        print(f"Weak fields source benchmark: {weak_fields_benchmark_name}")
    print(f"Variants found: {len(present)}")
    for v in present:
        n_log = len(variants_log_files[v])
        n_mon = len(variants_monitor_files.get(v, []))
        print(f"  {v:<20}: {n_log} log files, {n_mon} monitor files")
    print()

    # Aggregate GC metrics per variant
    print("Parsing and aggregating GC metrics...")
    variants_all_metrics = {}
    variants_agg_metrics = {}
    for variant in present:
        all_m, agg_m = aggregate_gc_metrics(variants_log_files[variant])
        # For single-object benchmark use max values as the primary statistic
        if use_max:
            for metric_data in all_m.values():
                metric_data["avg"] = metric_data["max"][:]
            for metric_data in agg_m.values():
                metric_data["avg"] = metric_data["max"]
                metric_data["avg_std"] = metric_data["max_std"]
        variants_all_metrics[variant] = all_m
        variants_agg_metrics[variant] = agg_m
        n_metrics = len(agg_m)
        n_samples = max((len(v2.get("avg", [])) for v2 in all_m.values()), default=0)
        print(f"  {variant:<20}: {n_metrics} metrics, {n_samples} samples per metric")
    print()

    # Print summary comparison table
    all_metric_names = sorted(set().union(*(m.keys() for m in variants_agg_metrics.values())))
    if all_metric_names:
        col_w = 14
        sep = "-" * (58 + col_w * len(present))
        print(sep)
        print(f"{'GC METRICS SUMMARY (mean over all runs)':^{len(sep)}}")
        print(sep)
        header_parts = [f"{'Metric':<50}", f"{'Unit':>6}"]
        for v in present:
            header_parts.append(f"{v:>{col_w}}")
        print("  ".join(header_parts))
        print(sep)
        for metric in all_metric_names:
            units = next(
                (variants_agg_metrics[v].get(metric, {}).get("units", "")
                 for v in present if variants_agg_metrics[v].get(metric, {}).get("units")),
                ""
            )
            row_parts = [f"{metric[:50]:<50}", f"{units:>6}"]
            for v in present:
                avg = variants_agg_metrics[v].get(metric, {}).get("avg", None)
                std = variants_agg_metrics[v].get(metric, {}).get("avg_std", None)
                if avg is not None and std is not None:
                    cell = f"{avg:.1f}\u00b1{std:.1f}"
                    row_parts.append(f"{cell:>{col_w}}")
                else:
                    row_parts.append(f"{'n/a':>{col_w}}")
            print("  ".join(row_parts))
        print(sep)
        print()

    # Generate boxplots for the key GC metrics
    metrics_to_plot = [
        "Major Collection: Major Collection",
        "Old Generation: Old Generation",
        "Old Subphase: Concurrent Mark Follow",
        "Old Subphase: Concurrent References Process",
        "Old Phase: Concurrent Process Non-Strong",
        "Young Generation: Young Generation",
        "Young Subphase: Concurrent Mark Follow",
    ]
    print("Generating metric boxplots...")
    plot_metric_boxplots(variants_all_metrics, present, metrics_to_plot, run_id, benchmark_mode_label)
    print("\u2713 Boxplots generated successfully!")

    # Continuous monitoring: aggregate and plot all variants
    if variants_monitor_files:
        print("\nAggregating continuous monitoring data...")
        variants_continuous = {}
        for variant in present:
            mon_files = variants_monitor_files.get(variant, [])
            if mon_files:
                cont = aggregate_monitor_files(mon_files)
                if cont:
                    variants_continuous[variant] = cont
                    print(f"  {variant:<20}: {len(cont)} samples")

        if variants_continuous:
            print("Generating continuous monitoring plot...")
            plot_continuous_monitoring_multi(variants_continuous, run_id, benchmark_mode_label)
            print("\u2713 Continuous monitoring plot generated!")

    print("\n" + "=" * 80)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
