#!/usr/bin/env python3
"""Parse GC benchmark CSV data and generate metric comparison artefacts.

Outputs for the interesting GC metrics:
1. Violin plots of per-run values for all variants.
2. Percentage-difference histograms of per-variant medians vs baseline variant "none".
3. LaTeX table with percentage differences of median and mean vs baseline.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


IMAGES_DIR = Path("images")
TABLES_DIR = Path("tables")
RESULTS_DIR = Path("results")

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


def find_newest_csv(results_dir: Path) -> Path | None:
    candidates = sorted(results_dir.glob("*_combined_variants.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", default=None, help="Path to combined variants CSV (default: newest in results/)")
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
    return parser.parse_args()


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
    young_gen_metric = (
        "Young Generation: Young Generation (Promote All)"
        if benchmark_mode == "single"
        else "Young Generation: Young Generation"
    )
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


def plot_violin_plots(
    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    variants: list[str],
    metrics_to_plot: list[str],
    run_label: str,
    output_dir: Path,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    for metric_name in metrics_to_plot:
        labels, data, units = metric_samples(variants_metrics, variants, metric_name)
        if not data:
            continue

        fig, axis = plt.subplots(figsize=(9, 5))
        violin = axis.violinplot(data, showmeans=True, showmedians=True, widths=0.85)

        palette = [plt.cm.tab10(i / max(len(data) - 1, 1)) for i in range(len(data))]
        for body, color in zip(violin["bodies"], palette):
            body.set_facecolor(color)
            body.set_edgecolor("black")
            body.set_alpha(0.75)

        for key in ["cbars", "cmins", "cmaxes", "cmedians", "cmeans"]:
            if key in violin:
                violin[key].set_color("black")
                violin[key].set_linewidth(1.0)

        axis.set_xticks(range(1, len(labels) + 1))
        axis.set_xticklabels(labels, rotation=15, ha="right")
        axis.set_ylim(bottom=0)
        axis.set_ylabel(f"Value ({units})" if units else "Value")
        axis.set_title(metric_name)
        axis.grid(True, axis="y", alpha=0.3)

        plt.tight_layout()
        safe_name = sanitize_metric_name(metric_name)
        output_file = output_dir / f"violin_{safe_name}_{run_label}.pdf"
        plt.savefig(output_file, bbox_inches="tight")
        plt.close(fig)
        print(f"Wrote {output_file}")


def compute_percent_diff(value: float, baseline_value: float) -> float:
    if baseline_value == 0.0:
        return 0.0
    return ((value - baseline_value) / baseline_value) * 100.0


def plot_median_diff_histograms(
    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]],
    variants: list[str],
    metrics_to_plot: list[str],
    run_label: str,
    output_dir: Path,
    baseline_variant: str,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    for metric_name in metrics_to_plot:
        baseline_values = list(
            variants_metrics.get(baseline_variant, {}).get(metric_name, {}).get("values", [])
        )
        if metric_name in FILTER_ZERO_METRICS:
            baseline_values = [value for value in baseline_values if value != 0.0]
        if not baseline_values:
            continue

        baseline_median = float(np.median(baseline_values))
        labels: list[str] = []
        diffs: list[float] = []

        for variant in variants:
            if variant == baseline_variant:
                continue
            variant_values = list(variants_metrics.get(variant, {}).get(metric_name, {}).get("values", []))
            if metric_name in FILTER_ZERO_METRICS:
                variant_values = [value for value in variant_values if value != 0.0]
            if not variant_values:
                continue

            variant_median = float(np.median(variant_values))
            labels.append(DISPLAY_NAMES.get(variant, variant))
            diffs.append(compute_percent_diff(variant_median, baseline_median))

        if not diffs:
            continue

        fig, axis = plt.subplots(figsize=(9, 5))
        bars = axis.bar(
            labels,
            diffs,
            color=[plt.cm.tab10(i / max(len(diffs) - 1, 1)) for i in range(len(diffs))],
            edgecolor="black",
            linewidth=0.8,
            alpha=0.85,
        )
        axis.axhline(0.0, color="black", linewidth=1.0, linestyle="--")
        axis.set_ylabel(f"Median difference vs {DISPLAY_NAMES.get(baseline_variant, baseline_variant)} (%)")
        axis.set_title(metric_name)
        axis.tick_params(axis="x", labelrotation=15)
        axis.grid(True, axis="y", alpha=0.3)

        for bar, diff in zip(bars, diffs):
            label_text = f"{diff:+.1f}%"
            y_pos = bar.get_height() + (0.6 if diff >= 0 else -0.6)
            va = "bottom" if diff >= 0 else "top"
            axis.text(bar.get_x() + bar.get_width() / 2.0, y_pos, label_text, ha="center", va=va, fontsize=8)

        plt.tight_layout()
        safe_name = sanitize_metric_name(metric_name)
        output_file = output_dir / f"median_diff_hist_{safe_name}_{run_label}.pdf"
        plt.savefig(output_file, bbox_inches="tight")
        plt.close(fig)
        print(f"Wrote {output_file}")


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
    csv_path: Path,
    benchmark_name: str,
    output_dir: Path,
    baseline_variant: str,
) -> int:
    use_max = benchmark_name == "single"
    variants_metrics = load_csv(csv_path, benchmark_name, use_max)

    if not variants_metrics:
        print(f"Warning: no '{benchmark_name}' benchmark rows found in {csv_path}")
        return 0

    present = [v for v in VARIANTS_ORDERED if v in variants_metrics]
    if baseline_variant not in present:
        print(
            f"Error: baseline variant '{baseline_variant}' not found for benchmark '{benchmark_name}'. "
            f"Present variants: {', '.join(present)}"
        )
        return 1

    metrics_to_plot = interesting_metrics(benchmark_name)
    run_label = f"{csv_path.stem}_{benchmark_name}"

    print(f"Generating violin plots for '{benchmark_name}'...")
    plot_violin_plots(variants_metrics, present, metrics_to_plot, run_label, output_dir)

    print(f"Generating median percentage-difference histograms for '{benchmark_name}'...")
    plot_median_diff_histograms(variants_metrics, present, metrics_to_plot, run_label, output_dir, baseline_variant)

    print(f"Generating LaTeX percentage-difference table for '{benchmark_name}'...")
    write_latex_percentage_table(variants_metrics, present, metrics_to_plot, run_label, baseline_variant)

    return 0


def main() -> int:
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

    exit_code = 0
    for benchmark_name in benchmarks:
        print("=" * 72)
        print(f"Processing benchmark mode: {benchmark_name}")
        code = generate_for_benchmark(csv_path, benchmark_name, output_dir, args.baseline)
        if code != 0:
            exit_code = code

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
