#!/usr/bin/env python3
"""Generate GC metric boxplot images and a summary table image from a combined variant CSV."""

import argparse
import csv
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np


VARIANTS_ORDERED = [
    "none", "clear_path_only", "sep_only", "dyn_only",
    "clear_path_sep", "clear_path_dyn", "sep_dyn", "all", "weak_fields",
]
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
FILTER_ZEROS_METRICS = {
    "Young Generation: Young Generation",
}


RESULTS_DIR = Path("results")


def find_newest_csv(results_dir: Path) -> Path | None:
    candidates = sorted(results_dir.glob("*_combined_variants.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", default=None, help="Path to combined variants CSV (default: newest in results/)")
    parser.add_argument("--benchmark", choices=["single", "multi"], default=None, help="Benchmark mode (default: both)")
    parser.add_argument("--output-dir", default="images", help="Output directory for PDFs (default: images)")
    return parser.parse_args()


def load_csv(csv_path, benchmark_name):
    """Load combined CSV; return (variants_all_metrics, variants_agg_metrics)."""
    variants_data = {}

    with open(csv_path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if row.get("benchmark") != benchmark_name:
                continue
            variant = row.get("variant", "").strip()
            metric_name = row.get("metric", "").strip()
            if not variant or not metric_name:
                continue
            variants_data.setdefault(variant, {})
            if metric_name not in variants_data[variant]:
                variants_data[variant][metric_name] = {"avg": [], "max": [], "units": row.get("units", "")}
            try:
                variants_data[variant][metric_name]["avg"].append(float(row["total_avg"]))
                variants_data[variant][metric_name]["max"].append(float(row["total_max"]))
            except (ValueError, KeyError):
                continue

    variants_agg = {}
    for variant, metrics in variants_data.items():
        agg = {}
        for metric_name, data in metrics.items():
            agg[metric_name] = {
                "avg": float(np.mean(data["avg"])) if data["avg"] else 0.0,
                "max": float(np.mean(data["max"])) if data["max"] else 0.0,
                "avg_std": float(np.std(data["avg"])) if len(data["avg"]) > 1 else 0.0,
                "max_std": float(np.std(data["max"])) if len(data["max"]) > 1 else 0.0,
                "units": data["units"],
            }
        variants_agg[variant] = agg

    return variants_data, variants_agg


def plot_metric_boxplots(variants_all_metrics, variants, metric_names, output_dir, run_label):
    output_dir.mkdir(parents=True, exist_ok=True)
    colors = [plt.cm.tab10(i / max(len(variants) - 1, 1)) for i in range(len(variants))]

    for metric_name in metric_names:
        if not any(metric_name in variants_all_metrics.get(v, {}) for v in variants):
            continue

        fig, ax = plt.subplots(figsize=(8, 5))
        filter_zeros = metric_name in FILTER_ZEROS_METRICS

        data_per_variant = []
        labels = []
        for variant in variants:
            values = list(variants_all_metrics.get(variant, {}).get(metric_name, {}).get("avg", []))
            if values and filter_zeros:
                values = [v for v in values if v != 0.0]
            data_per_variant.append(values)
            labels.append(DISPLAY_NAMES.get(variant, variant))

        non_empty = [(d, l, c) for d, l, c in zip(data_per_variant, labels, colors) if d]
        if not non_empty:
            plt.close()
            continue
        data_filtered, labels_filtered, colors_filtered = zip(*non_empty)

        bp = ax.boxplot(data_filtered, labels=labels_filtered, patch_artist=True, notch=False)
        for patch, color in zip(bp["boxes"], colors_filtered):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)

        units = next(
            (variants_all_metrics.get(v, {}).get(metric_name, {}).get("units", "")
             for v in variants if variants_all_metrics.get(v, {}).get(metric_name, {}).get("units")),
            "",
        )
        ax.set_title(metric_name, fontsize=12, fontweight="bold")
        ax.set_ylabel(f"Value ({units})" if units else "Value", fontsize=10)
        ax.set_ylim(bottom=0)
        ax.tick_params(axis="x", labelsize=9, rotation=15)
        ax.grid(True, alpha=0.3, axis="y")

        plt.tight_layout()
        safe_name = metric_name.replace(": ", "_").replace(" ", "_").replace("(", "").replace(")", "").lower()
        output_file = output_dir / f"boxplot_{safe_name}_{run_label}.pdf"
        plt.savefig(output_file, bbox_inches="tight")
        print(f"  {output_file}")
        plt.close()


def plot_summary_table(variants_agg, variants, output_dir, run_label):
    all_metric_names = sorted(set().union(*(m.keys() for m in variants_agg.values())))
    if not all_metric_names:
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    col_headers = ["Metric", "Unit"] + [DISPLAY_NAMES.get(v, v).replace("\n", " ") for v in variants]

    rows = []
    for metric in all_metric_names:
        units = next(
            (variants_agg[v].get(metric, {}).get("units", "") for v in variants if variants_agg[v].get(metric, {}).get("units")),
            "",
        )
        row = [metric, units]
        for v in variants:
            avg = variants_agg[v].get(metric, {}).get("avg")
            std = variants_agg[v].get(metric, {}).get("avg_std")
            row.append(f"{avg:.1f}\u00b1{std:.1f}" if avg is not None and std is not None else "n/a")
        rows.append(row)

    n_cols = len(col_headers)
    fig, ax = plt.subplots(figsize=(max(10, 2 * n_cols), max(2, 0.35 * len(rows) + 1)))
    ax.axis("off")
    table = ax.table(cellText=rows, colLabels=col_headers, loc="center", cellLoc="left")
    table.auto_set_font_size(False)
    table.set_fontsize(7)
    table.auto_set_column_width(list(range(n_cols)))
    plt.tight_layout()
    output_file = output_dir / f"summary_table_{run_label}.pdf"
    plt.savefig(output_file, bbox_inches="tight")
    print(f"  {output_file}")
    plt.close()


def generate_for_benchmark(csv_path, benchmark_name, output_dir):
    variants_all_metrics, variants_agg_metrics = load_csv(csv_path, benchmark_name)
    if not variants_all_metrics:
        print(f"Warning: no '{benchmark_name}' benchmark rows found in {csv_path}")
        return

    present = [v for v in VARIANTS_ORDERED if v in variants_all_metrics]

    if benchmark_name == "single":
        for all_m in variants_all_metrics.values():
            for metric_data in all_m.values():
                metric_data["avg"] = metric_data["max"][:]
        for agg_m in variants_agg_metrics.values():
            for metric_data in agg_m.values():
                metric_data["avg"] = metric_data["max"]
                metric_data["avg_std"] = metric_data["max_std"]

    young_gen_metric = (
        "Young Generation: Young Generation (Promote All)"
        if benchmark_name == "single"
        else "Young Generation: Young Generation"
    )
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

    run_label = f"{csv_path.stem}_{benchmark_name}"
    plot_metric_boxplots(variants_all_metrics, present, metrics_to_plot, output_dir, run_label)
    plot_summary_table(variants_agg_metrics, present, output_dir, run_label)


def main():
    args = parse_args()
    if args.csv:
        csv_path = Path(args.csv)
    else:
        csv_path = find_newest_csv(RESULTS_DIR)
        if csv_path is None:
            print(f"Error: no *_combined_variants.csv found in {RESULTS_DIR}")
            return 1
        print(f"Using {csv_path}")
    output_dir = Path(args.output_dir)

    benchmarks = [args.benchmark] if args.benchmark else ["multi", "single"]
    for benchmark_name in benchmarks:
        generate_for_benchmark(csv_path, benchmark_name, output_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
