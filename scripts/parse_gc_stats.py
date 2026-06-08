#!/usr/bin/env python3
"""Parse GC benchmark CSV data and generate metric comparison artefacts.

Outputs:
1. Composite GC plots (violin + median-diff histogram) for each metric.
2. LaTeX table with percentage differences of median and mean vs baseline.
3. Memory plots: max-per-variant violin and median-diff histograms.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.lines import Line2D


def _add_yaxis_break(ax: Any) -> None:
    """Draw conventional double-diagonal axis-break marks (//) on the y-axis at y=0."""
    # Two short diagonal lines crossing the spine, in axes coordinates
    d = 0.012   # half-height of each slash in axes coords
    gap = 0.018  # vertical gap between the two slashes
    x0 = 0.0
    kw = dict(transform=ax.transAxes, color="black", linewidth=1.5, clip_on=False, zorder=10, solid_capstyle="round")
    cover = dict(transform=ax.transAxes, color="white", linewidth=6, clip_on=False, zorder=9)
    for y0 in (-gap / 2, gap / 2):
        ax.plot([x0 - 0.04, x0 + 0.04], [y0 - d, y0 + d], **cover)
        ax.plot([x0 - 0.03, x0 + 0.03], [y0 - d, y0 + d], **kw)


IMAGES_DIR = Path("images")
TABLES_DIR = Path("tables")
RESULTS_DIR = Path("results")
OUTPUT_ROOT_DIR = Path("output")
PANEL_H = 4.0  # inches per subplot panel — kept constant across all figures

VARIANTS_ORDERED = [
    "none",
    "clear_path_only",
    "sep_only",
    "dyn_only",
    "clear_path_sep",
    "clear_path_dyn",
    "sep_dyn",
    "all",
    "weak_fields",
]

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

FILTER_ZERO_METRICS = {
    "Young Generation: Young Generation",
}

# Metrics included in per-variant summary statistics tables
SUMMARY_METRICS: list[tuple[str, str, str]] = [
    ("Old Phase: Concurrent Process Non-Strong",          "Non-Strong Processing",              "nonstrong"),
    ("Major Collection: Major Collection",                "Major Collection",                   "major"),
    ("Old Generation: Old Generation",                    "Old Generation",                     "oldgen"),
    ("Old Phase: Concurrent Mark",                        "Old Phase: Concurrent Mark",         "old-concurrent-mark"),
    ("Old Phase: Concurrent Relocate",                    "Old Phase: Concurrent Relocate",     "old-relocate"),
    ("Young Generation: Young Generation (Promote All)",  "Young Generation (Promote All)",     "young-gen"),
    ("Young Phase: Concurrent Mark",                      "Young Phase: Concurrent Mark",       "young-concurrent-mark"),
    ("Young Phase: Concurrent Relocate",                  "Young Phase: Concurrent Relocate",   "young-relocate"),
    ("Old Subphase: Concurrent Mark Follow",              "Concurrent Mark Follow",             "markfollow"),
]

# LaTeX display names for variants (underscores escaped for use inside \texttt{})
LATEX_VARIANT_NAMES: dict[str, str] = {
    "none":            r"\texttt{none}",
    "clear_path_only": r"\texttt{clear\_path\_only}",
    "dyn_only":        r"\texttt{dyn\_only}",
    "sep_only":        r"\texttt{sep\_only}",
    "sep_dyn":         r"\texttt{sep\_dyn}",
    "clear_path_dyn":  r"\texttt{clear\_path\_dyn}",
    "clear_path_sep":  r"\texttt{clear\_path\_sep}",
    "all":             r"\texttt{all}",
    "weak_fields":     r"\texttt{weak\_fields}",
}

MEMORY_METRICS = {
    "aux": {
        "column": "gc_committed_kb",
        "title": "Aux Memory",
        "short": "Auxiliary GC memory summary statistics",
        "unit": "MB",
    },
    "java_heap": {
        "column": "heap_kb",
        "title": "Java Heap",
        "short": "Java heap summary statistics",
        "unit": "MB",
    },
    "rss": {
        "column": "rss_kb",
        "title": "RSS",
        "short": "Total process RSS summary statistics",
        "unit": "MB",
    },
}


def find_newest_gc_csv(results_dir: Path) -> Path | None:
    new_candidates = sorted(results_dir.glob("*_combined_gc.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    if new_candidates:
        return new_candidates[0]

    legacy_candidates = sorted(
        results_dir.glob("*_combined_variants.csv"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return legacy_candidates[0] if legacy_candidates else None


def infer_memory_csv_from_gc_csv(gc_csv_path: Path) -> Path | None:
    stem = gc_csv_path.stem
    if stem.endswith("_combined_gc"):
        candidate = gc_csv_path.with_name(stem.replace("_combined_gc", "_combined_memory") + gc_csv_path.suffix)
        return candidate if candidate.exists() else None
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--csv",
        default=None,
        help="Path to GC CSV (supports *_combined_gc.csv and legacy *_combined_variants.csv; default: newest in results/)",
    )
    parser.add_argument(
        "--memory-csv",
        default=None,
        help="Path to memory CSV (default: inferred *_combined_memory.csv next to --csv)",
    )
    parser.add_argument(
        "--benchmark",
        choices=["single", "multi"],
        default=None,
        help="Benchmark mode (default: both)",
    )
    parser.add_argument(
        "--baseline",
        default="none",
        help="Baseline variant name for percentage differences (default: none)",
    )
    parser.add_argument(
        "--output-dir",
        default="images",
        help="Output directory for PDFs (default: images)",
    )
    parser.add_argument(
        "--benchmark-output-root",
        default=str(OUTPUT_ROOT_DIR),
        help="Benchmark output root that contains id_<run-id>/memory directories (default: output)",
    )
    return parser.parse_args()


def run_id_for_benchmark(csv_path: Path, benchmark_name: str) -> str | None:
    with open(csv_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("benchmark") == benchmark_name:
                run_id = (row.get("run_id") or "").strip()
                if run_id:
                    return run_id
    return None


def load_csv(csv_path: Path, benchmark_name: str, use_max: bool) -> dict[str, dict[str, dict[str, list[float] | str]]]:
    """Load combined CSV and return variants_metrics with a 'values' key per metric.

    For single benchmarks, 'values' is drawn from total_max; for multi, from total_avg.
    """
    raw: dict[str, dict[str, dict[str, list]]] = {}

    with open(csv_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("benchmark") != benchmark_name:
                continue
            variant = row.get("variant", "").strip()
            metric_name = row.get("metric", "").strip()
            if not variant or not metric_name:
                continue
            raw.setdefault(variant, {})
            if metric_name not in raw[variant]:
                raw[variant][metric_name] = {"avg": [], "max": [], "units": row.get("units", "")}
            try:
                raw[variant][metric_name]["avg"].append(float(row["total_avg"]))
                raw[variant][metric_name]["max"].append(float(row["total_max"]))
            except (ValueError, KeyError):
                continue

    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]] = {}
    for variant, metrics in raw.items():
        variants_metrics[variant] = {}
        for metric_name, data in metrics.items():
            values = data["max"] if use_max else data["avg"]
            variants_metrics[variant][metric_name] = {
                "values": values,
                "units": data["units"],
            }
    return variants_metrics


def interesting_metrics(benchmark_mode: str) -> list[str]:
    young_gen_metric = "Young Generation: Young Generation (Promote All)"
    return [
        "Major Collection: Major Collection",
        "Old Generation: Old Generation",
        "Old Phase: Concurrent Mark",
        "Old Phase: Concurrent Process Non-Strong",
        "Old Phase: Concurrent Relocate",
        young_gen_metric,
        "Young Phase: Concurrent Mark",
        "Young Phase: Concurrent Relocate",
    ]


def sanitize_metric_name(metric_name: str) -> str:
    return (
        metric_name.replace(": ", "_")
        .replace(" ", "_")
        .replace("(", "")
        .replace(")", "")
        .lower()
    )


def metric_samples(
    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    variants: list[str],
    metric_name: str,
) -> tuple[list[str], list[list[float]], str]:
    labels: list[str] = []
    data: list[list[float]] = []
    units = ""

    for variant in variants:
        values = list(variants_metrics.get(variant, {}).get(metric_name, {}).get("values", []))
        if metric_name in FILTER_ZERO_METRICS:
            values = [value for value in values if value != 0.0]

        if values:
            labels.append(DISPLAY_NAMES.get(variant, variant))
            data.append(values)
            if not units:
                units = str(variants_metrics[variant][metric_name].get("units", ""))

    return labels, data, units


def plot_composite_gc(
    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    variants: list[str],
    metrics_to_plot: list[str],
    run_label: str,
    output_dir: Path,
    baseline_variant: str,
    benchmark_name: str,
) -> None:
    """Composite figure: violin (top) + median-diff histogram (bottom), grouped by metric."""
    output_dir.mkdir(parents=True, exist_ok=True)

    benchmark_label = "Single-Object Benchmark" if benchmark_name == "single" else "Multi-Object Benchmark"

    for metric_name in metrics_to_plot:
        # --- violin data (all variants) ---
        violin_labels, violin_data, units = metric_samples(variants_metrics, variants, metric_name)
        if not violin_data:
            continue

        # --- histogram data: all variants, baseline shown as 0 ---
        baseline_values = list(
            variants_metrics.get(baseline_variant, {}).get(metric_name, {}).get("values", [])
        )
        if metric_name in FILTER_ZERO_METRICS:
            baseline_values = [v for v in baseline_values if v != 0.0]
        if not baseline_values:
            continue
        baseline_median = float(np.median(baseline_values))

        hist_labels: list[str] = []
        hist_diffs: list[float] = []
        for variant in variants:
            if variant == baseline_variant:
                hist_labels.append(DISPLAY_NAMES.get(variant, variant))
                hist_diffs.append(0.0)
                continue
            var_values = list(variants_metrics.get(variant, {}).get(metric_name, {}).get("values", []))
            if metric_name in FILTER_ZERO_METRICS:
                var_values = [v for v in var_values if v != 0.0]
            if not var_values:
                continue
            hist_labels.append(DISPLAY_NAMES.get(variant, variant))
            hist_diffs.append(compute_percent_diff(float(np.median(var_values)), baseline_median))

        if len(hist_labels) < 2:
            continue

        # Shared colour palette keyed by display label so both panels match
        all_labels = violin_labels  # violin covers all variants that have data
        palette = {lbl: plt.cm.tab10(i / max(len(all_labels) - 1, 1)) for i, lbl in enumerate(all_labels)}

        fig, (ax_violin, ax_hist) = plt.subplots(
            2, 1, figsize=(9, 2 * PANEL_H), sharex=False,
            constrained_layout=True,
        )

        # ---- Violin panel ----
        violin = ax_violin.violinplot(violin_data, showmeans=True, showmedians=True, widths=0.85)
        for body, lbl in zip(violin["bodies"], violin_labels):
            body.set_facecolor(palette.get(lbl, "grey"))
            body.set_edgecolor("black")
            body.set_alpha(0.75)
        for key in ["cbars", "cmins", "cmaxes"]:
            if key in violin:
                violin[key].set_color("black")
                violin[key].set_linewidth(1.0)
        if "cmedians" in violin:
            violin["cmedians"].set_color("black")
            violin["cmedians"].set_linewidth(2.0)
            violin["cmedians"].set_linestyle("-")
        if "cmeans" in violin:
            violin["cmeans"].set_color("black")
            violin["cmeans"].set_linewidth(1.5)
            violin["cmeans"].set_linestyle("--")

        ax_violin.set_xticks(range(1, len(violin_labels) + 1))
        ax_violin.set_xticklabels([], visible=False)
        ax_violin.tick_params(axis="x", bottom=False)
        v_bot, v_top = ax_violin.get_ylim()
        v_pad = (v_top - v_bot) * 0.05
        ax_violin.set_ylim(bottom=v_bot - v_pad, top=v_top + v_pad)
        _add_yaxis_break(ax_violin)
        ax_violin.set_ylabel(f"Value ({units})" if units else "Value")
        ax_violin.grid(True, axis="y", alpha=0.3)

        legend_handles = [
            Line2D([0], [0], color="black", linewidth=2.0, linestyle="-", label="Median"),
            Line2D([0], [0], color="black", linewidth=1.5, linestyle="--", label="Mean"),
        ]
        ax_violin.legend(handles=legend_handles, loc="upper right", framealpha=0.8)

        # ---- Histogram panel ----
        bar_colors = [palette.get(lbl, "grey") for lbl in hist_labels]
        bars = ax_hist.bar(
            hist_labels,
            hist_diffs,
            color=bar_colors,
            edgecolor="black",
            linewidth=0.8,
            alpha=0.85,
        )
        ax_hist.axhline(0.0, color="black", linewidth=1.0, linestyle="--")
        baseline_display = DISPLAY_NAMES.get(baseline_variant, baseline_variant)
        ax_hist.set_ylabel(f"Median diff vs {baseline_display} (%)")
        ax_hist.tick_params(axis="x", labelrotation=15)
        ax_hist.grid(True, axis="y", alpha=0.3)

        # Annotate bars
        y_range = max(abs(d) for d in hist_diffs) if hist_diffs else 1.0
        offset = y_range * 0.03 or 0.3
        for bar, diff in zip(bars, hist_diffs):
            label_text = f"{diff:+.1f}%"
            y_pos = bar.get_height() + (offset if diff >= 0 else -offset)
            va = "bottom" if diff >= 0 else "top"
            ax_hist.text(
                bar.get_x() + bar.get_width() / 2.0,
                y_pos,
                label_text,
                ha="center",
                va=va,
                fontsize=8,
            )
        h_min, h_max = ax_hist.get_ylim()
        h_pad = (h_max - h_min) * 0.15
        ax_hist.set_ylim(h_min - h_pad, h_max + h_pad)

        # ---- Shared title ----
        fig.suptitle(f"{metric_name} — {benchmark_label}", fontsize=12, fontweight="bold")

        safe_name = sanitize_metric_name(metric_name)
        output_file = output_dir / f"composite_{safe_name}_{run_label}.pdf"
        plt.savefig(output_file, bbox_inches="tight")
        plt.close(fig)
        print(f"Wrote {output_file}")



def parse_monitor_file(monitor_file: Path) -> dict[str, dict[str, list[float]]] | None:
    timestamps_ms: list[float] = []
    columns_kb: dict[str, list[float]] = {
        "rss_kb": [],
        "gc_committed_kb": [],
        "heap_kb": [],
    }

    with monitor_file.open(encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line.startswith("[monitor_data]"):
                continue

            payload = line.split("]", maxsplit=1)
            if len(payload) < 2:
                continue
            parts = payload[1].strip().split(",")
            if len(parts) < 5:
                continue

            try:
                timestamp = float(parts[0])
                rss_kb = float(parts[1])
                gc_committed_kb = float(parts[3])
                heap_kb = float(parts[4])
            except ValueError:
                continue

            timestamps_ms.append(timestamp)
            columns_kb["rss_kb"].append(rss_kb)
            columns_kb["gc_committed_kb"].append(gc_committed_kb)
            columns_kb["heap_kb"].append(heap_kb)

    if not timestamps_ms:
        return None

    t0 = timestamps_ms[0]
    times_s = [(ts - t0) / 1000.0 for ts in timestamps_ms]
    parsed: dict[str, dict[str, list[float]]] = {}
    for column, values_kb in columns_kb.items():
        values_mb = [value / 1024.0 for value in values_kb]
        parsed[column] = {
            "times": times_s,
            "values": values_mb,
        }
    return parsed


def memory_benchmark_name(benchmark_name: str, variant: str) -> str:
    if variant == "weak_fields":
        return "field-single" if benchmark_name == "single" else "field"
    return benchmark_name


def load_memory_traces(
    output_root: Path,
    run_id: str,
    benchmark_name: str,
    variants: list[str],
) -> dict[str, dict[str, list[dict[str, Any]]]]:
    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]] = {}
    memory_dir = output_root / f"id_{run_id}" / "memory"

    if not memory_dir.exists():
        print(f"Warning: memory directory not found: {memory_dir}")
        return traces_by_variant

    for variant in variants:
        benchmark_label = memory_benchmark_name(benchmark_name, variant)
        pattern = f"monitor_{benchmark_label}_{variant}_run*_{run_id}.csv"
        monitor_files = sorted(memory_dir.glob(pattern), key=lambda p: p.name)
        if not monitor_files:
            continue

        traces_by_variant[variant] = {metric_key: [] for metric_key in MEMORY_METRICS}
        for monitor_file in monitor_files:
            parsed = parse_monitor_file(monitor_file)
            if not parsed:
                continue

            for metric_key, info in MEMORY_METRICS.items():
                column = str(info["column"])
                trace = parsed.get(column)
                if not trace:
                    continue

                values = list(trace["values"])
                if not values:
                    continue

                traces_by_variant[variant][metric_key].append(
                    {
                        "times": list(trace["times"]),
                        "values": values,
                        "max": float(max(values)),
                    }
                )

    return traces_by_variant


def load_memory_traces_from_csv(
    memory_csv_path: Path,
    benchmark_name: str,
    variants: list[str],
) -> dict[str, dict[str, list[dict[str, Any]]]]:
    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]] = {}
    if not memory_csv_path.exists():
        return traces_by_variant

    grouped: dict[tuple[str, str], list[tuple[float, dict[str, float]]]] = {}

    with open(memory_csv_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("benchmark") != benchmark_name:
                continue
            variant = (row.get("variant") or "").strip()
            source_log = (row.get("source_log") or "").strip()
            if not variant or variant not in variants:
                continue

            timestamp_raw = (row.get("timestamp_ms") or "").strip()
            if not timestamp_raw:
                continue
            try:
                timestamp_ms = float(timestamp_raw)
            except ValueError:
                continue

            values_kb: dict[str, float] = {}
            for info in MEMORY_METRICS.values():
                column = str(info["column"])
                raw_value = (row.get(column) or "").strip()
                if not raw_value:
                    continue
                try:
                    values_kb[column] = float(raw_value)
                except ValueError:
                    continue

            key = (variant, source_log or f"{variant}_{int(timestamp_ms)}")
            grouped.setdefault(key, []).append((timestamp_ms, values_kb))

    for (variant, _source_log), samples in grouped.items():
        samples.sort(key=lambda item: item[0])
        timestamps = [sample[0] for sample in samples]
        if not timestamps:
            continue
        t0 = timestamps[0]

        traces_by_variant.setdefault(variant, {metric_key: [] for metric_key in MEMORY_METRICS})

        for metric_key, info in MEMORY_METRICS.items():
            column = str(info["column"])
            times_s: list[float] = []
            values_mb: list[float] = []

            for timestamp_ms, value_map in samples:
                if column not in value_map:
                    continue
                value_kb = value_map[column]
                times_s.append((timestamp_ms - t0) / 1000.0)
                values_mb.append(value_kb / 1024.0)

            if not values_mb:
                continue

            traces_by_variant[variant][metric_key].append(
                {
                    "times": times_s,
                    "values": values_mb,
                    "max": float(max(values_mb)),
                }
            )

    return traces_by_variant


def plot_memory_max_per_variant(
    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]],
    variants: list[str],
    benchmark_name: str,
    run_label: str,
    output_dir: Path,
) -> None:
    """Single figure with one violin panel per memory metric, stacked vertically."""
    output_dir.mkdir(parents=True, exist_ok=True)

    metrics = list(MEMORY_METRICS.items())
    n = len(metrics)
    fig, axes = plt.subplots(n, 1, figsize=(9, n * PANEL_H), constrained_layout=True)
    if n == 1:
        axes = [axes]

    benchmark_label = "Single-Object Benchmark" if benchmark_name == "single" else "Multi-Object Benchmark"
    fig.suptitle(f"Memory Per-Run Maxima — {benchmark_label}", fontsize=12, fontweight="bold")

    for ax, (metric_key, info) in zip(axes, metrics):
        labels: list[str] = []
        data: list[list[float]] = []
        for variant in variants:
            runs = traces_by_variant.get(variant, {}).get(metric_key, [])
            max_values = [float(run.get("max", 0.0)) for run in runs if "max" in run]
            if not max_values:
                continue
            labels.append(DISPLAY_NAMES.get(variant, variant))
            data.append(max_values)

        if not data:
            ax.set_visible(False)
            continue

        palette = [plt.cm.tab10(i / max(len(data) - 1, 1)) for i in range(len(data))]
        violin = ax.violinplot(data, showmeans=True, showmedians=True, widths=0.85)
        for body, color in zip(violin["bodies"], palette):
            body.set_facecolor(color)
            body.set_edgecolor("black")
            body.set_alpha(0.75)
        for key in ["cbars", "cmins", "cmaxes"]:
            if key in violin:
                violin[key].set_color("black")
                violin[key].set_linewidth(1.0)
        if "cmedians" in violin:
            violin["cmedians"].set_color("black")
            violin["cmedians"].set_linewidth(2.0)
            violin["cmedians"].set_linestyle("-")
        if "cmeans" in violin:
            violin["cmeans"].set_color("black")
            violin["cmeans"].set_linewidth(1.5)
            violin["cmeans"].set_linestyle("--")

        ax.set_xticks(range(1, len(labels) + 1))
        ax.set_xticklabels(labels, rotation=15, ha="right")
        v_bot, v_top = ax.get_ylim()
        v_pad = (v_top - v_bot) * 0.05
        ax.set_ylim(bottom=v_bot - v_pad, top=v_top + v_pad)
        _add_yaxis_break(ax)
        ax.set_ylabel(f"Max ({info['unit']})")
        ax.set_title(str(info["title"]))
        ax.grid(True, axis="y", alpha=0.3)

    legend_handles = [
        Line2D([0], [0], color="black", linewidth=2.0, linestyle="-", label="Median"),
        Line2D([0], [0], color="black", linewidth=1.5, linestyle="--", label="Mean"),
    ]
    axes[0].legend(handles=legend_handles, loc="upper right", framealpha=0.8)

    output_file = output_dir / f"memory_max_{run_label}.pdf"
    plt.savefig(output_file, bbox_inches="tight")
    plt.close(fig)
    print(f"Wrote {output_file}")


def plot_memory_median_diff_histograms(
    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]],
    variants: list[str],
    run_label: str,
    output_dir: Path,
    baseline_variant: str,
    benchmark_name: str,
) -> None:
    """Single figure with one histogram panel per memory metric, stacked vertically."""
    output_dir.mkdir(parents=True, exist_ok=True)

    baseline_display = DISPLAY_NAMES.get(baseline_variant, baseline_variant)
    benchmark_label = "Single-Object Benchmark" if benchmark_name == "single" else "Multi-Object Benchmark"
    metrics = list(MEMORY_METRICS.items())
    n = len(metrics)
    fig, axes = plt.subplots(n, 1, figsize=(9, n * PANEL_H), constrained_layout=True)
    if n == 1:
        axes = [axes]

    fig.suptitle(f"Memory Median Differences vs {baseline_display} — {benchmark_label}", fontsize=12, fontweight="bold")

    for ax, (metric_key, info) in zip(axes, metrics):
        baseline_runs = traces_by_variant.get(baseline_variant, {}).get(metric_key, [])
        baseline_maxima = [float(run.get("max", 0.0)) for run in baseline_runs if "max" in run]
        if not baseline_maxima:
            ax.set_visible(False)
            continue
        baseline_median = float(np.median(baseline_maxima))

        labels: list[str] = []
        diffs: list[float] = []
        for variant in variants:
            if variant == baseline_variant:
                continue
            runs = traces_by_variant.get(variant, {}).get(metric_key, [])
            maxima = [float(run.get("max", 0.0)) for run in runs if "max" in run]
            if not maxima:
                continue
            labels.append(DISPLAY_NAMES.get(variant, variant))
            diffs.append(compute_percent_diff(float(np.median(maxima)), baseline_median))

        if not diffs:
            ax.set_visible(False)
            continue

        bars = ax.bar(
            labels,
            diffs,
            color=[plt.cm.tab10(i / max(len(diffs) - 1, 1)) for i in range(len(diffs))],
            edgecolor="black",
            linewidth=0.8,
            alpha=0.85,
        )
        ax.axhline(0.0, color="black", linewidth=1.0, linestyle="--")
        ax.set_ylabel(f"Median diff vs {baseline_display} (%)")
        ax.set_title(str(info["title"]))
        ax.tick_params(axis="x", labelrotation=15)
        ax.grid(True, axis="y", alpha=0.3)

        y_range = max(abs(d) for d in diffs) if diffs else 1.0
        offset = y_range * 0.03 or 0.3
        for bar, diff in zip(bars, diffs):
            label_text = f"{diff:+.1f}%"
            y_pos = bar.get_height() + (offset if diff >= 0 else -offset)
            va = "bottom" if diff >= 0 else "top"
            ax.text(bar.get_x() + bar.get_width() / 2.0, y_pos, label_text, ha="center", va=va, fontsize=8)
        h_min, h_max = ax.get_ylim()
        h_pad = (h_max - h_min) * 0.15
        ax.set_ylim(h_min - h_pad, h_max + h_pad)

    output_file = output_dir / f"memory_median_diff_hist_{run_label}.pdf"
    plt.savefig(output_file, bbox_inches="tight")
    plt.close(fig)
    print(f"Wrote {output_file}")


def plot_memory_composite_per_metric(
    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]],
    variants: list[str],
    benchmark_name: str,
    run_label: str,
    output_dir: Path,
    baseline_variant: str,
) -> None:
    """One composite violin+diff-hist figure per memory metric (one PDF each).

    Output filenames: ``memory_composite_{metric_key}_{run_label}.pdf``
    Mirrors the style of ``plot_composite_gc`` so the presentation can show each
    memory type independently.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    benchmark_label = "Single-Object Benchmark" if benchmark_name == "single" else "Multi-Object Benchmark"
    baseline_display = DISPLAY_NAMES.get(baseline_variant, baseline_variant)

    for metric_key, info in MEMORY_METRICS.items():
        unit = str(info["unit"])
        title = str(info["title"])

        # ---- Violin data (all variants that have traces) ----
        violin_labels: list[str] = []
        violin_data: list[list[float]] = []
        for variant in variants:
            runs = traces_by_variant.get(variant, {}).get(metric_key, [])
            max_values = [float(run["max"]) for run in runs if "max" in run]
            if max_values:
                violin_labels.append(DISPLAY_NAMES.get(variant, variant))
                violin_data.append(max_values)

        if not violin_data:
            continue

        # ---- Baseline for diff-hist ----
        baseline_runs = traces_by_variant.get(baseline_variant, {}).get(metric_key, [])
        baseline_maxima = [float(run["max"]) for run in baseline_runs if "max" in run]
        if not baseline_maxima:
            continue
        baseline_median = float(np.median(baseline_maxima))

        # ---- Diff-hist data (all variants, baseline shown as 0) ----
        hist_labels: list[str] = []
        hist_diffs: list[float] = []
        for variant in variants:
            runs = traces_by_variant.get(variant, {}).get(metric_key, [])
            max_values = [float(run["max"]) for run in runs if "max" in run]
            if not max_values and variant != baseline_variant:
                continue
            lbl = DISPLAY_NAMES.get(variant, variant)
            hist_labels.append(lbl)
            if variant == baseline_variant:
                hist_diffs.append(0.0)
            else:
                hist_diffs.append(compute_percent_diff(float(np.median(max_values)), baseline_median))

        if len(hist_labels) < 2:
            continue

        # Shared palette keyed by display label
        palette = {lbl: plt.cm.tab10(i / max(len(violin_labels) - 1, 1)) for i, lbl in enumerate(violin_labels)}

        fig, (ax_violin, ax_hist) = plt.subplots(
            2, 1, figsize=(9, 2 * PANEL_H), sharex=False, constrained_layout=True,
        )

        # ---- Violin panel ----
        violin = ax_violin.violinplot(violin_data, showmeans=True, showmedians=True, widths=0.85)
        for body, lbl in zip(violin["bodies"], violin_labels):
            body.set_facecolor(palette.get(lbl, "grey"))
            body.set_edgecolor("black")
            body.set_alpha(0.75)
        for key in ["cbars", "cmins", "cmaxes"]:
            if key in violin:
                violin[key].set_color("black")
                violin[key].set_linewidth(1.0)
        if "cmedians" in violin:
            violin["cmedians"].set_color("black")
            violin["cmedians"].set_linewidth(2.0)
            violin["cmedians"].set_linestyle("-")
        if "cmeans" in violin:
            violin["cmeans"].set_color("black")
            violin["cmeans"].set_linewidth(1.5)
            violin["cmeans"].set_linestyle("--")

        ax_violin.set_xticks(range(1, len(violin_labels) + 1))
        ax_violin.set_xticklabels([], visible=False)
        ax_violin.tick_params(axis="x", bottom=False)
        v_bot, v_top = ax_violin.get_ylim()
        v_pad = (v_top - v_bot) * 0.05
        ax_violin.set_ylim(bottom=v_bot - v_pad, top=v_top + v_pad)
        _add_yaxis_break(ax_violin)
        ax_violin.set_ylabel(f"Peak per run ({unit})")
        ax_violin.grid(True, axis="y", alpha=0.3)

        legend_handles = [
            Line2D([0], [0], color="black", linewidth=2.0, linestyle="-", label="Median"),
            Line2D([0], [0], color="black", linewidth=1.5, linestyle="--", label="Mean"),
        ]
        ax_violin.legend(handles=legend_handles, loc="upper right", framealpha=0.8)

        # ---- Diff-hist panel ----
        bar_colors = [palette.get(lbl, "grey") for lbl in hist_labels]
        bars = ax_hist.bar(
            hist_labels, hist_diffs,
            color=bar_colors, edgecolor="black", linewidth=0.8, alpha=0.85,
        )
        ax_hist.axhline(0.0, color="black", linewidth=1.0, linestyle="--")
        ax_hist.set_ylabel(f"Median diff vs {baseline_display} (%)")
        ax_hist.tick_params(axis="x", labelrotation=15)
        ax_hist.grid(True, axis="y", alpha=0.3)

        y_range = max(abs(d) for d in hist_diffs) if hist_diffs else 1.0
        offset = y_range * 0.03 or 0.3
        for bar, diff in zip(bars, hist_diffs):
            label_text = f"{diff:+.1f}%"
            y_pos = bar.get_height() + (offset if diff >= 0 else -offset)
            va = "bottom" if diff >= 0 else "top"
            ax_hist.text(
                bar.get_x() + bar.get_width() / 2.0,
                y_pos, label_text, ha="center", va=va, fontsize=8,
            )
        h_min, h_max = ax_hist.get_ylim()
        h_pad = (h_max - h_min) * 0.15
        ax_hist.set_ylim(h_min - h_pad, h_max + h_pad)

        fig.suptitle(f"{title} — {benchmark_label}", fontsize=12, fontweight="bold")

        out = output_dir / f"memory_composite_{metric_key}_{run_label}.pdf"
        plt.savefig(out, bbox_inches="tight")
        plt.close(fig)
        print(f"Wrote {out}")


def plot_memory_hist_per_metric(
    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]],
    variants: list[str],
    benchmark_name: str,
    run_label: str,
    output_dir: Path,
    baseline_variant: str,
) -> None:
    """Diff-histogram-only figure per memory metric (one PDF each).

    Output filenames: ``memory_hist_{metric_key}_{run_label}.pdf``
    Used by the presentation to show compact memory comparisons.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    benchmark_label = "Single-Object Benchmark" if benchmark_name == "single" else "Multi-Object Benchmark"
    baseline_display = DISPLAY_NAMES.get(baseline_variant, baseline_variant)

    for metric_key, info in MEMORY_METRICS.items():
        title = str(info["title"])

        baseline_runs = traces_by_variant.get(baseline_variant, {}).get(metric_key, [])
        baseline_maxima = [float(run["max"]) for run in baseline_runs if "max" in run]
        if not baseline_maxima:
            continue
        baseline_median = float(np.median(baseline_maxima))

        hist_labels: list[str] = []
        hist_diffs: list[float] = []
        for variant in variants:
            runs = traces_by_variant.get(variant, {}).get(metric_key, [])
            max_values = [float(run["max"]) for run in runs if "max" in run]
            if not max_values and variant != baseline_variant:
                continue
            lbl = DISPLAY_NAMES.get(variant, variant)
            hist_labels.append(lbl)
            if variant == baseline_variant:
                hist_diffs.append(0.0)
            else:
                hist_diffs.append(compute_percent_diff(float(np.median(max_values)), baseline_median))

        if len(hist_labels) < 2:
            continue

        palette = {lbl: plt.cm.tab10(i / max(len(hist_labels) - 1, 1)) for i, lbl in enumerate(hist_labels)}

        fig, ax = plt.subplots(1, 1, figsize=(9, PANEL_H), constrained_layout=True)

        bar_colors = [palette.get(lbl, "grey") for lbl in hist_labels]
        bars = ax.bar(
            hist_labels, hist_diffs,
            color=bar_colors, edgecolor="black", linewidth=0.8, alpha=0.85,
        )
        ax.axhline(0.0, color="black", linewidth=1.0, linestyle="--")
        ax.set_ylabel(f"Median diff vs {baseline_display} (%)")
        ax.tick_params(axis="x", labelrotation=15)
        ax.grid(True, axis="y", alpha=0.3)

        y_range = max(abs(d) for d in hist_diffs) if hist_diffs else 1.0
        offset = y_range * 0.03 or 0.3
        for bar, diff in zip(bars, hist_diffs):
            label_text = f"{diff:+.1f}%"
            y_pos = bar.get_height() + (offset if diff >= 0 else -offset)
            va = "bottom" if diff >= 0 else "top"
            ax.text(
                bar.get_x() + bar.get_width() / 2.0,
                y_pos, label_text, ha="center", va=va, fontsize=8,
            )

        h_min, h_max = ax.get_ylim()
        h_pad = (h_max - h_min) * 0.15
        ax.set_ylim(h_min - h_pad, h_max + h_pad)

        ax.set_title(f"{title} — {benchmark_label}", fontsize=12, fontweight="bold")

        out = output_dir / f"memory_hist_{metric_key}_{run_label}.pdf"
        plt.savefig(out, bbox_inches="tight")
        plt.close(fig)
        print(f"Wrote {out}")


def compute_percent_diff(value: float, baseline_value: float) -> float:
    if baseline_value == 0.0:
        return 0.0
    return ((value - baseline_value) / baseline_value) * 100.0



def escape_latex(text: str) -> str:
    escaped = text
    for old, new in [
        ("\\", r"\\textbackslash{}"),
        ("_", r"\\_"),
        ("%", r"\\%"),
        ("&", r"\\&"),
        ("#", r"\\#"),
        ("$", r"\\$"),
        ("{", r"\\{"),
        ("}", r"\\}"),
    ]:
        escaped = escaped.replace(old, new)
    return escaped


def _gc_stats(values: list[float]) -> tuple[float, float, float]:
    """Return (median, mean, IQR) for a list of floats."""
    if not values:
        return 0.0, 0.0, 0.0
    med = float(np.median(values))
    mn = float(np.mean(values))
    iqr = float(np.quantile(values, 0.75) - np.quantile(values, 0.25))
    return med, mn, iqr


def write_latex_summary_stats_tables(
    single_variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    multi_variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    variants: list[str],
    run_prefix: str,
    single_traces: dict[str, dict[str, list[dict[str, Any]]]],
    multi_traces: dict[str, dict[str, list[dict[str, Any]]]],
) -> None:
    """Write one LaTeX table per GC metric and one per memory metric.

    Each table has rows = variants and columns = Median / Mean / IQR for the
    single-object benchmark and the multi-object benchmark side by side.
    Files are written to TABLES_DIR as ``stats_<metric>_<run_prefix>.tex`` and
    ``stats_memory_<key>_<run_prefix>.tex``.
    """
    TABLES_DIR.mkdir(parents=True, exist_ok=True)

    # ---- GC timing tables ----
    header_row_ms = r" & \multicolumn{3}{c}{Single (ms)} & \multicolumn{3}{c}{Multi (ms)} \\"
    subheader_row = r"\cmidrule(lr){2-4}\cmidrule(lr){5-7}"
    col_row = r"Variant & Median & Mean & IQR & Median & Mean & IQR \\"
    for metric_key, metric_label, metric_slug in SUMMARY_METRICS:
        lines: list[str] = []
        lines.append(r"\begin{longtable}{l rrr rrr}")
        lines.append(
            rf"\caption[{metric_label} summary statistics]{{Summary statistics for \textbf{{{metric_label}}} across all variants. "
            rf"Values in ms; single-object benchmark uses per-run maxima, "
            rf"multi-object uses per-run averages ($n=250$ per variant).}}"
            rf"\label{{tab:stats-{metric_slug}}} \\"
        )
        lines.append(r"\toprule")
        lines.append(header_row_ms)
        lines.append(subheader_row)
        lines.append(col_row)
        lines.append(r"\midrule")
        lines.append(r"\endfirsthead")
        lines.append(r"\toprule")
        lines.append(header_row_ms)
        lines.append(subheader_row)
        lines.append(col_row)
        lines.append(r"\midrule")
        lines.append(r"\endhead")
        lines.append(r"\bottomrule")
        lines.append(r"\endfoot")

        for variant in variants:
            s_vals = list(single_variants_metrics.get(variant, {}).get(metric_key, {}).get("values", []))
            m_vals = list(multi_variants_metrics.get(variant, {}).get(metric_key, {}).get("values", []))
            if not s_vals and not m_vals:
                continue
            s_med, s_mn, s_iqr = _gc_stats(s_vals)
            m_med, m_mn, m_iqr = _gc_stats(m_vals)
            vname = LATEX_VARIANT_NAMES.get(variant, variant)
            lines.append(
                f"{vname} & "
                f"{s_med:.1f} & {s_mn:.1f} & {s_iqr:.1f} & "
                f"{m_med:.1f} & {m_mn:.1f} & {m_iqr:.1f} \\\\"
            )

        lines.append(r"\end{longtable}")

        out = TABLES_DIR / f"stats_{metric_slug}_{run_prefix}.tex"
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Wrote {out}")

    # ---- Memory statistics tables ----
    for mem_key in ("aux", "java_heap", "rss"):
        mem_info = MEMORY_METRICS[mem_key]
        unit = str(mem_info["unit"])
        title = str(mem_info["title"])
        slug = mem_key.replace("_", "-")

        lines = []
        lines.append(r"\begin{longtable}{l rrr rrr}")
        short = str(mem_info["short"])
        lines.append(
            rf"\caption[{short}]{{Summary statistics for \textbf{{{title}}} per-run maximum across all variants. "
            rf"Values in {unit} ($n=250$ per variant).}}"
            rf"\label{{tab:stats-memory-{slug}}} \\"
        )
        lines.append(r"\toprule")
        lines.append(rf" & \multicolumn{{3}}{{c}}{{Single ({unit})}} & \multicolumn{{3}}{{c}}{{Multi ({unit})}} \\")
        lines.append(r"\cmidrule(lr){2-4}\cmidrule(lr){5-7}")
        lines.append(r"Variant & Median & Mean & IQR & Median & Mean & IQR \\")
        lines.append(r"\midrule")
        lines.append(r"\endfirsthead")
        lines.append(r"\toprule")
        lines.append(rf" & \multicolumn{{3}}{{c}}{{Single ({unit})}} & \multicolumn{{3}}{{c}}{{Multi ({unit})}} \\")
        lines.append(r"\cmidrule(lr){2-4}\cmidrule(lr){5-7}")
        lines.append(r"Variant & Median & Mean & IQR & Median & Mean & IQR \\")
        lines.append(r"\midrule")
        lines.append(r"\endhead")
        lines.append(r"\bottomrule")
        lines.append(r"\endfoot")

        for variant in variants:
            s_maxes = [float(r["max"]) for r in single_traces.get(variant, {}).get(mem_key, []) if "max" in r]
            m_maxes = [float(r["max"]) for r in multi_traces.get(variant, {}).get(mem_key, []) if "max" in r]
            if not s_maxes and not m_maxes:
                continue
            s_med, s_mn, s_iqr = _gc_stats(s_maxes)
            m_med, m_mn, m_iqr = _gc_stats(m_maxes)
            vname = LATEX_VARIANT_NAMES.get(variant, variant)
            lines.append(
                f"{vname} & "
                f"{s_med:.0f} & {s_mn:.0f} & {s_iqr:.0f} & "
                f"{m_med:.0f} & {m_mn:.0f} & {m_iqr:.0f} \\\\"
            )

        lines.append(r"\end{longtable}")

        out = TABLES_DIR / f"stats_memory_{mem_key}_{run_prefix}.tex"
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Wrote {out}")


def write_latex_percentage_table(
    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    variants: list[str],
    metrics_to_plot: list[str],
    run_label: str,
    baseline_variant: str,
) -> None:
    TABLES_DIR.mkdir(parents=True, exist_ok=True)

    lines: list[str] = []
    lines.append(r"\begin{table}[t]")
    lines.append(r"\centering")
    lines.append(
        rf"\caption{{Percentage differences vs {escape_latex(DISPLAY_NAMES.get(baseline_variant, baseline_variant))} for median and mean values ({escape_latex(run_label)}).}}"
    )
    lines.append(rf"\label{{tab:gc_metric_pct_diff_{escape_latex(run_label)}}}")
    lines.append(r"\begin{tabular}{llrr}")
    lines.append(r"\toprule")
    lines.append(r"Metric & Variant & Median diff (\%) & Mean diff (\%) \\")
    lines.append(r"\midrule")

    for metric_name in metrics_to_plot:
        baseline_values = list(
            variants_metrics.get(baseline_variant, {}).get(metric_name, {}).get("values", [])
        )
        if metric_name in FILTER_ZERO_METRICS:
            baseline_values = [value for value in baseline_values if value != 0.0]
        if not baseline_values:
            continue

        baseline_median = float(np.median(baseline_values))
        baseline_mean = float(np.mean(baseline_values))

        for variant in variants:
            if variant == baseline_variant:
                continue
            values = list(variants_metrics.get(variant, {}).get(metric_name, {}).get("values", []))
            if metric_name in FILTER_ZERO_METRICS:
                values = [value for value in values if value != 0.0]
            if not values:
                continue

            median_diff = compute_percent_diff(float(np.median(values)), baseline_median)
            mean_diff = compute_percent_diff(float(np.mean(values)), baseline_mean)

            lines.append(
                f"{escape_latex(metric_name)} & "
                f"{escape_latex(DISPLAY_NAMES.get(variant, variant))} & "
                f"{median_diff:+.2f} & {mean_diff:+.2f} \\\\"
            )

    lines.append(r"\bottomrule")
    lines.append(r"\end{tabular}")
    lines.append(r"\end{table}")

    output_file = TABLES_DIR / f"gc_metric_pct_diff_{run_label}.tex"
    output_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {output_file}")


def generate_for_benchmark(
    gc_csv_path: Path,
    memory_csv_path: Path | None,
    benchmark_name: str,
    output_dir: Path,
    benchmark_output_root: Path,
    baseline_variant: str,
) -> tuple[int, dict[str, dict[str, dict[str, list[float] | str]]], dict[str, dict[str, list[dict[str, Any]]]], list[str], str]:
    """Process one benchmark mode.

    Returns (exit_code, variants_metrics, traces_by_variant, present_variants, run_label).
    """
    use_max = benchmark_name == "single"
    variants_metrics = load_csv(gc_csv_path, benchmark_name, use_max)

    if not variants_metrics:
        print(f"Warning: no '{benchmark_name}' benchmark rows found in {gc_csv_path}")
        return 0, {}, {}, [], ""

    present = [v for v in VARIANTS_ORDERED if v in variants_metrics]
    if baseline_variant not in present:
        print(
            f"Error: baseline variant '{baseline_variant}' not found for benchmark '{benchmark_name}'. "
            f"Present variants: {', '.join(present)}"
        )
        return 1, {}, {}, [], ""

    metrics_to_plot = interesting_metrics(benchmark_name)
    run_label = f"{gc_csv_path.stem}_{benchmark_name}"

    print(f"Generating composite GC plots for '{benchmark_name}'...")
    plot_composite_gc(variants_metrics, present, metrics_to_plot, run_label, output_dir, baseline_variant, benchmark_name)

    print(f"Generating LaTeX percentage-difference table for '{benchmark_name}'...")
    write_latex_percentage_table(variants_metrics, present, metrics_to_plot, run_label, baseline_variant)

    traces_by_variant: dict[str, dict[str, list[dict[str, Any]]]] = {}
    if memory_csv_path is not None:
        traces_by_variant = load_memory_traces_from_csv(memory_csv_path, benchmark_name, present)

    if not traces_by_variant:
        run_id = run_id_for_benchmark(gc_csv_path, benchmark_name)
        if run_id:
            traces_by_variant = load_memory_traces(benchmark_output_root, run_id, benchmark_name, present)

    if not traces_by_variant:
        print(f"Warning: no memory traces found for benchmark '{benchmark_name}'")
        return 0, variants_metrics, {}, present, run_label

    print(f"Generating memory max-per-variant plots for '{benchmark_name}'...")
    plot_memory_max_per_variant(traces_by_variant, present, benchmark_name, run_label, output_dir)

    print(f"Generating memory median percentage-difference histograms for '{benchmark_name}'...")
    plot_memory_median_diff_histograms(traces_by_variant, present, run_label, output_dir, baseline_variant, benchmark_name)

    print(f"Generating per-metric memory composite plots for '{benchmark_name}'...")
    plot_memory_composite_per_metric(traces_by_variant, present, benchmark_name, run_label, output_dir, baseline_variant)

    print(f"Generating per-metric memory histogram plots for '{benchmark_name}'...")
    plot_memory_hist_per_metric(traces_by_variant, present, benchmark_name, run_label, output_dir, baseline_variant)

    return 0, variants_metrics, traces_by_variant, present, run_label


def main() -> int:
    args = parse_args()

    if args.csv:
        gc_csv_path = Path(args.csv)
    else:
        gc_csv_path = find_newest_gc_csv(RESULTS_DIR)
        if gc_csv_path is None:
            print(f"Error: no *_combined_gc.csv or *_combined_variants.csv found in {RESULTS_DIR}")
            return 1
        print(f"Using {gc_csv_path}")

    memory_csv_path: Path | None
    if args.memory_csv:
        memory_csv_path = Path(args.memory_csv)
        if not memory_csv_path.exists():
            print(f"Warning: memory CSV not found: {memory_csv_path}")
            memory_csv_path = None
    else:
        memory_csv_path = infer_memory_csv_from_gc_csv(gc_csv_path)
        if memory_csv_path is not None:
            print(f"Using {memory_csv_path}")

    output_dir = Path(args.output_dir)
    benchmark_output_root = Path(args.benchmark_output_root)
    benchmarks = [args.benchmark] if args.benchmark else ["multi", "single"]

    exit_code = 0
    collected: dict[str, dict] = {}
    for benchmark_name in benchmarks:
        print("=" * 72)
        print(f"Processing benchmark mode: {benchmark_name}")
        code, vm, traces, present, run_label = generate_for_benchmark(
            gc_csv_path,
            memory_csv_path,
            benchmark_name,
            output_dir,
            benchmark_output_root,
            args.baseline,
        )
        if code != 0:
            exit_code = code
        if vm:
            collected[benchmark_name] = {
                "variants_metrics": vm,
                "traces": traces,
                "present": present,
                "run_label": run_label,
            }

    # Write combined summary statistics tables when both benchmarks were processed
    if "single" in collected and "multi" in collected:
        run_prefix = gc_csv_path.stem
        # Use the union of present variants, preserving VARIANTS_ORDERED order
        all_present: list[str] = [v for v in VARIANTS_ORDERED
                                   if v in collected["single"]["present"]
                                   or v in collected["multi"]["present"]]
        print("=" * 72)
        print("Generating summary statistics tables...")
        write_latex_summary_stats_tables(
            collected["single"]["variants_metrics"],
            collected["multi"]["variants_metrics"],
            all_present,
            run_prefix,
            collected["single"]["traces"],
            collected["multi"]["traces"],
        )

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
