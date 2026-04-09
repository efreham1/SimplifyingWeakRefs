#!/usr/bin/env python3
"""
Parse continuous memory monitoring data and generate plots.
Aggregates data across outer runs with run tracking.
"""

import re
import sys
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np


OUTPUT_ROOT = Path("output")


def get_run_output_dir(run_id):
    """Return the per-run output directory for a benchmark execution id."""
    return OUTPUT_ROOT / f"id_{run_id}"


def collect_run_files(run_id, subdir, pattern):
    """Collect result files from the per-run output layout."""
    result_dir = get_run_output_dir(run_id) / subdir
    return [str(path) for path in sorted(result_dir.glob(pattern), key=lambda path: path.name)]


def parse_continuous_monitor_data(filename):
    """Parse continuous memory monitoring data from CSV file."""
    monitor_data = []
    
    if not Path(filename).exists():
        print(f"Warning: {filename} not found")
        return monitor_data
    
    with open(filename) as f:
        for line in f:
            if "[monitor_data]" in line:
                # Format: [monitor_data] timestamp_ms,rss_kb,gc_reserved_kb,gc_committed_kb,heap_kb,phase
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


def plot_metric_boxplots(variants_all_metrics, variants, metric_names, run_id=1, benchmark_mode_label="multi"):
    """Plot one boxplot per metric, each saved as a separate PDF.

    Each plot compares all variant configs side-by-side so distributions
    across the full set of runs can be compared at a glance.
    """
    Path('images').mkdir(parents=True, exist_ok=True)

    DISPLAY_NAMES = {
        "none": "None",
        "all": "All",
        "clear_path_only": "Clear Path",
        "sep_only": "Sep",
        "dyn_only": "Dyn",
        "clear_path_sep": "Clear Path\n+ Sep",
        "clear_path_dyn": "Clear Path\n+ Dyn",
        "sep_dyn": "Sep + Dyn",
        "weak_fields": "Weak Fields",
    }

    # Metrics where zero values should be filtered out (typically only
    # recorded during certain GC cycles, so zeros are missing data).
    FILTER_ZEROS_METRICS = {
        "Young Generation: Young Generation",
    }

    # Keep only metrics that have data in at least one variant
    metrics_to_plot = [
        m for m in metric_names
        if any(m in variants_all_metrics.get(v, {}) for v in variants)
    ]

    if not metrics_to_plot:
        print("Warning: none of the requested metrics found in data")
        return

    # Distinct colours for up to 9 variants
    colors = [plt.cm.tab10(i / max(len(variants) - 1, 1)) for i in range(len(variants))]

    for metric_name in metrics_to_plot:
        fig, ax = plt.subplots(figsize=(8, 5))

        filter_zeros = metric_name in FILTER_ZEROS_METRICS

        data_per_variant = []
        labels = []
        for variant in variants:
            values = variants_all_metrics.get(variant, {}).get(metric_name, {}).get("avg", [])
            if values and filter_zeros:
                values = [v for v in values if v != 0.0]
            data_per_variant.append(values if values else [])
            labels.append(DISPLAY_NAMES.get(variant, variant))

        # Remove variants with no data so the plot is not cluttered with empty boxes
        non_empty = [(d, l, c) for d, l, c in zip(data_per_variant, labels, colors) if d]
        if not non_empty:
            ax.text(0.5, 0.5, 'No data', ha='center', va='center', transform=ax.transAxes)
            ax.set_title(metric_name, fontsize=12, fontweight='bold')
            plt.close()
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

        ax.set_title(metric_name, fontsize=12, fontweight='bold')
        ax.set_ylabel(f"Value ({units})" if units else "Value", fontsize=10)
        ax.set_ylim(bottom=0)
        ax.tick_params(axis='x', labelsize=9, rotation=15)
        ax.grid(True, alpha=0.3, axis='y')

        plt.tight_layout()
        # Build a filesystem-safe name from the metric
        safe_name = metric_name.replace(": ", "_").replace(" ", "_").replace("(", "").replace(")", "").lower()
        output_file = f'images/boxplot_{safe_name}_{benchmark_mode_label}_{run_id}.pdf'
        plt.savefig(output_file, bbox_inches='tight')
        print(f"  {output_file}")
        plt.close()


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


def plot_continuous_monitoring_multi(variants_continuous, run_id=1, benchmark_mode_label="multi"):
    """Plot mean RSS, GC-auxiliary, and heap usage over time for N variant configs.

    Each memory metric is saved as a separate PDF.  Every variant is drawn as a
    distinct colour with shaded ±1 std-dev bands.
    """
    Path('images').mkdir(parents=True, exist_ok=True)

    DISPLAY_NAMES = {
        "none": "None",
        "all": "All",
        "clear_path_only": "Clear Path",
        "sep_only": "Sep",
        "dyn_only": "Dyn",
        "clear_path_sep": "Clear Path + Sep",
        "clear_path_dyn": "Clear Path + Dyn",
        "sep_dyn": "Sep + Dyn",
        "weak_fields": "Weak Fields",
    }

    if not variants_continuous:
        print("No continuous monitoring data to plot")
        return

    variant_list = list(variants_continuous.keys())
    colors = [plt.cm.tab10(i / max(len(variant_list) - 1, 1)) for i in range(len(variant_list))]

    # Define the three memory metrics to plot individually
    memory_metrics = [
        {
            "key": "rss",
            "value_key": "rss_kb",
            "std_key": "rss_std_kb",
            "ylabel": "Total Process RSS (MB)",
            "title": "Total Process Memory (Mean \u00b1 Std Dev)",
            "safe_name": "rss",
        },
        {
            "key": "gc",
            "value_key": "gc_committed_kb",
            "std_key": "gc_std_kb",
            "ylabel": "GC Auxiliary Memory (MB)",
            "title": "GC Auxiliary Memory (Mean \u00b1 Std Dev)",
            "safe_name": "gc_auxiliary",
        },
        {
            "key": "heap",
            "value_key": "heap_kb",
            "std_key": "heap_std_kb",
            "ylabel": "Java Heap (MB)",
            "title": "Java Heap Usage (Mean \u00b1 Std Dev)",
            "safe_name": "java_heap",
        },
    ]

    for mm in memory_metrics:
        fig, ax = plt.subplots(figsize=(10, 5))

        for variant, color in zip(variant_list, colors):
            data = variants_continuous[variant]
            if not data:
                continue
            label = DISPLAY_NAMES.get(variant, variant)
            times = [(d['timestamp_ms'] - data[0]['timestamp_ms']) / 1000.0 for d in data]
            values = [d.get(mm["value_key"], 0) / 1024.0 for d in data]
            stds = [d.get(mm["std_key"], 0) / 1024.0 for d in data]

            ax.plot(times, values, linewidth=1.5, label=label, color=color, alpha=0.85)
            ax.fill_between(times,
                            [v - s for v, s in zip(values, stds)],
                            [v + s for v, s in zip(values, stds)],
                            color=color, alpha=0.15, linewidth=0)

        ax.set_xlabel('Time (seconds)', fontsize=12)
        ax.set_ylabel(mm["ylabel"], fontsize=12)
        ax.set_ylim(bottom=0)
        ax.set_title(mm["title"], fontsize=13, fontweight='bold')
        ax.legend(fontsize=10)
        ax.grid(True, alpha=0.3)

        plt.tight_layout()
        output_file = f'images/memory_{mm["safe_name"]}_{benchmark_mode_label}_{run_id}.pdf'
        plt.savefig(output_file, bbox_inches='tight')
        print(f"  {output_file}")
        plt.close()


def main():
    # Parse command line arguments
    run_id = 1
    if len(sys.argv) > 1:
        if sys.argv[1] == "--id" and len(sys.argv) > 2:
            run_id = sys.argv[2]
        elif sys.argv[1].startswith("--id="):
            run_id = sys.argv[1].split("=")[1]

    # Auto-detect benchmark mode from the current per-run output files.
    # When weak_fields is enabled, this run id contains both primary benchmark
    # logs and weak_fields logs. Determine whether this is the multi or single mode.
    candidate_files = collect_run_files(run_id, "logs", f"run_*_*_run*_{run_id}.log")
    benchmark_name = "multi"  # default
    if candidate_files:
        multi_count = 0
        single_count = 0
        for f in candidate_files:
            base = Path(f).name
            if base.startswith("run_single_") or base.startswith("run_field-single_"):
                single_count += 1
            elif base.startswith("run_multi_") or base.startswith("run_field_"):
                multi_count += 1

        if single_count > multi_count:
            benchmark_name = "single"
    use_max = benchmark_name == "single"
    benchmark_mode_label = benchmark_name

    weak_fields_benchmark_name = "field-single" if benchmark_name == "single" else "field"

    # Canonical variant order (matches scripts/run_benchmark_iterations.sh)
    VARIANTS_ORDERED = [
        "none", "clear_path_only", "sep_only", "dyn_only",
        "clear_path_sep", "clear_path_dyn", "sep_dyn", "all", "weak_fields",
    ]

    # Discover which variants actually produced output files for this run_id.
    variants_log_files = {}
    variants_monitor_files = {}
    for variant in VARIANTS_ORDERED:
        source_benchmarks = [weak_fields_benchmark_name] if variant == "weak_fields" else [benchmark_name]

        log_files = []
        monitor_files = []
        for source_benchmark in source_benchmarks:
            log_files.extend(collect_run_files(run_id, "logs", f"run_{source_benchmark}_{variant}_*_{run_id}.log"))
            monitor_files.extend(collect_run_files(run_id, "memory", f"monitor_{source_benchmark}_{variant}_*_{run_id}.csv"))
        log_files = sorted(set(log_files))
        monitor_files = sorted(set(monitor_files))
        if log_files:
            variants_log_files[variant] = log_files
        if monitor_files:
            variants_monitor_files[variant] = monitor_files

    if not variants_log_files:
        print(f"Error: no log files found for run id '{run_id}' in {get_run_output_dir(run_id)}")
        print("Make sure you have run:")
        print("  bash scripts/run_benchmark_iterations.sh")
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
    young_gen_metric = ("Young Generation: Young Generation (Promote All)"
                        if benchmark_mode_label == "single"
                        else "Young Generation: Young Generation")
    metrics_to_plot = [
        "Major Collection: Major Collection",
        "Old Generation: Old Generation",
        "Old Phase: Concurrent Mark",
        "Old Phase: Concurrent Process Non-Strong",
        "Old Phase: Concurrent Relocate",
        young_gen_metric,
        "Young Phase: Concurrent Mark",
        "Young Phase: Concurrent Relocate",
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
