#!/usr/bin/env python3
"""Parse GC benchmark logs and generate metric comparison artefacts.

Outputs for the interesting GC metrics:
1. Violin plots of per-run values for all variants.
2. Percentage-difference histograms of per-variant medians vs baseline variant "none".
3. LaTeX table with percentage differences of median and mean vs baseline.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


OUTPUT_ROOT = Path("output")
IMAGES_DIR = Path("images")
TABLES_DIR = Path("tables")

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

FILTER_ZERO_METRICS = {
    "Young Generation: Young Generation",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--id",
        default="1",
        help=(
            "Run id in output/id_<id>. If unsuffixed, the script automatically "
            "processes both <id>-single and <id>-multi when present."
        ),
    )
    parser.add_argument(
        "--baseline",
        default="none",
        help="Baseline variant name for percentage differences (default: none)",
    )
    return parser.parse_args()


def get_run_output_dir(run_id: str) -> Path:
    return OUTPUT_ROOT / f"id_{run_id}"


def normalise_run_id(run_id: str) -> str:
    """Accept both '<id>' and 'id_<id>' user input formats."""
    return run_id[3:] if run_id.startswith("id_") else run_id


def collect_run_files(run_id: str, subdir: str, pattern: str) -> list[str]:
    result_dir = get_run_output_dir(run_id) / subdir
    return [str(path) for path in sorted(result_dir.glob(pattern), key=lambda path: path.name)]


def detect_benchmark_mode(run_id: str) -> str:
    candidate_files = collect_run_files(run_id, "logs", f"run_*_*_run*_{run_id}.log")
    benchmark_name = "multi"
    if not candidate_files:
        return benchmark_name

    multi_count = 0
    single_count = 0
    for filename in candidate_files:
        base = Path(filename).name
        if base.startswith("run_single_") or base.startswith("run_field-single_"):
            single_count += 1
        elif base.startswith("run_multi_") or base.startswith("run_field_"):
            multi_count += 1

    if single_count > multi_count:
        benchmark_name = "single"
    return benchmark_name


def resolve_run_ids(requested_id: str) -> list[str]:
    """Resolve requested run id to one or more concrete run ids to process."""
    requested_id = normalise_run_id(requested_id)

    if requested_id.endswith("-single") or requested_id.endswith("-multi"):
        return [requested_id]

    resolved: list[str] = []
    for suffix in ["single", "multi"]:
        candidate = f"{requested_id}-{suffix}"
        if get_run_output_dir(candidate).exists():
            resolved.append(candidate)

    if resolved:
        return resolved

    # Fallback for legacy/non-suffixed layouts.
    return [requested_id]


def parse_gc_stats_file(filename: str) -> dict[str, dict[str, list[float] | str]]:
    """Parse a run log and extract GC metrics with Total Avg/Max values and units."""
    metrics: dict[str, dict[str, list[float] | str]] = {}

    if not Path(filename).exists():
        return metrics

    with open(filename, encoding="utf-8") as handle:
        for line in handle:
            if "[gc,stats]" not in line:
                continue

            line = line.strip()
            if any(token in line for token in ["Last 10s", "Avg / Max", "==="]):
                continue

            match = re.search(r"\[gc,stats\](.*)", line)
            if not match:
                continue

            data = match.group(1).strip()
            pairs = list(re.finditer(r"(\d+\.?\d*)\s*/\s*(\d+\.?\d*)", data))
            if len(pairs) < 4:
                continue

            total_avg = float(pairs[3].group(1))
            total_max = float(pairs[3].group(2))

            metric_start = re.search(r"\d", data)
            if not metric_start:
                continue
            metric_name = data[: metric_start.start()].strip()
            if not metric_name:
                continue

            units_match = re.search(r"(\d+\.?\d*)\s*/\s*(\d+\.?\d*)\s+(\S+)\s*$", data)
            units = units_match.group(3) if units_match else ""

            if metric_name not in metrics:
                metrics[metric_name] = {"avg": [], "max": [], "units": units}
            metrics[metric_name]["avg"].append(total_avg)  # type: ignore[index]
            metrics[metric_name]["max"].append(total_max)  # type: ignore[index]

    return metrics


def aggregate_gc_metrics(log_files: list[str], use_max: bool) -> dict[str, dict[str, list[float] | str]]:
    """Aggregate GC metric samples across all run log files for one variant."""
    all_metrics: dict[str, dict[str, list[float] | str]] = {}

    for filename in log_files:
        parsed = parse_gc_stats_file(filename)
        for metric_name, metric_data in parsed.items():
            if metric_name not in all_metrics:
                all_metrics[metric_name] = {
                    "avg": [],
                    "max": [],
                    "units": metric_data["units"],
                }
            all_metrics[metric_name]["avg"].extend(metric_data["avg"])  # type: ignore[index]
            all_metrics[metric_name]["max"].extend(metric_data["max"])  # type: ignore[index]

    # Re-map into one canonical sample list key "values" to simplify downstream code.
    canonical: dict[str, dict[str, list[float] | str]] = {}
    for metric_name, metric_data in all_metrics.items():
        values = metric_data["max"] if use_max else metric_data["avg"]
        canonical[metric_name] = {"values": values, "units": metric_data["units"]}
    return canonical


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
    run_id: str,
    benchmark_mode: str,
) -> None:
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

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
        output_file = IMAGES_DIR / f"violin_{safe_name}_{benchmark_mode}_{run_id}.pdf"
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
    run_id: str,
    benchmark_mode: str,
    baseline_variant: str,
) -> None:
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

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
            label = f"{diff:+.1f}%"
            y_pos = bar.get_height() + (0.6 if diff >= 0 else -0.6)
            va = "bottom" if diff >= 0 else "top"
            axis.text(bar.get_x() + bar.get_width() / 2.0, y_pos, label, ha="center", va=va, fontsize=8)

        plt.tight_layout()
        safe_name = sanitize_metric_name(metric_name)
        output_file = IMAGES_DIR / f"median_diff_hist_{safe_name}_{benchmark_mode}_{run_id}.pdf"
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
    run_id: str,
    benchmark_mode: str,
    baseline_variant: str,
) -> None:
    TABLES_DIR.mkdir(parents=True, exist_ok=True)

    lines: list[str] = []
    lines.append(r"\\begin{table}[t]")
    lines.append(r"\\centering")
    lines.append(
        rf"\\caption{{Percentage differences vs {escape_latex(DISPLAY_NAMES.get(baseline_variant, baseline_variant))} for median and mean values ({escape_latex(benchmark_mode)} mode, run id {escape_latex(str(run_id))}).}}"
    )
    lines.append(rf"\\label{{tab:gc_metric_pct_diff_{escape_latex(benchmark_mode)}_{escape_latex(str(run_id))}}}")
    lines.append(r"\\begin{tabular}{llrr}")
    lines.append(r"\\toprule")
    lines.append(r"Metric & Variant & Median diff (\\%) & Mean diff (\\%) \\")
    lines.append(r"\\midrule")

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

    lines.append(r"\\bottomrule")
    lines.append(r"\\end{tabular}")
    lines.append(r"\\end{table}")

    output_file = TABLES_DIR / f"gc_metric_pct_diff_{benchmark_mode}_{run_id}.tex"
    output_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {output_file}")


def process_run_id(run_id: str, baseline_variant: str) -> int:
    benchmark_mode = detect_benchmark_mode(run_id)
    use_max = benchmark_mode == "single"
    weak_fields_source = "field-single" if benchmark_mode == "single" else "field"

    variants_log_files: dict[str, list[str]] = {}
    for variant in VARIANTS_ORDERED:
        source_benchmarks = [weak_fields_source] if variant == "weak_fields" else [benchmark_mode]
        log_files: list[str] = []
        for source_benchmark in source_benchmarks:
            pattern = f"run_{source_benchmark}_{variant}_*_{run_id}.log"
            log_files.extend(collect_run_files(run_id, "logs", pattern))
        log_files = sorted(set(log_files))
        if log_files:
            variants_log_files[variant] = log_files

    if not variants_log_files:
        print(f"Error: no log files found for run id '{run_id}' in {get_run_output_dir(run_id)}")
        print("Run benchmark collection first with scripts/run_benchmark_iterations.sh")
        return 1

    present_variants = [variant for variant in VARIANTS_ORDERED if variant in variants_log_files]
    if baseline_variant not in present_variants:
        print(
            f"Error: baseline variant '{baseline_variant}' not found in run id '{run_id}'. "
            f"Present variants: {', '.join(present_variants)}"
        )
        return 1

    print(f"Run ID: {run_id}")
    print(f"Benchmark mode: {benchmark_mode} ({'max' if use_max else 'avg'} per-run values)")
    print(f"Baseline variant: {baseline_variant}")

    variants_metrics: dict[str, dict[str, dict[str, list[float] | str]]] = {}
    for variant in present_variants:
        variants_metrics[variant] = aggregate_gc_metrics(variants_log_files[variant], use_max=use_max)

    metrics_to_plot = interesting_metrics(benchmark_mode)

    print("Generating violin plots...")
    plot_violin_plots(variants_metrics, present_variants, metrics_to_plot, run_id, benchmark_mode)

    print("Generating median percentage-difference histograms...")
    plot_median_diff_histograms(
        variants_metrics,
        present_variants,
        metrics_to_plot,
        run_id,
        benchmark_mode,
        baseline_variant,
    )

    print("Generating LaTeX percentage-difference table...")
    write_latex_percentage_table(
        variants_metrics,
        present_variants,
        metrics_to_plot,
        run_id,
        benchmark_mode,
        baseline_variant,
    )

    return 0


def main() -> int:
    args = parse_args()
    requested_id = normalise_run_id(str(args.id))
    baseline_variant = args.baseline
    run_ids = resolve_run_ids(requested_id)

    if len(run_ids) > 1:
        print(f"Resolved base run id '{requested_id}' to: {', '.join(run_ids)}")

    exit_code = 0
    for run_id in run_ids:
        print("=" * 72)
        print(f"Processing run id: {run_id}")
        code = process_run_id(run_id, baseline_variant)
        if code != 0:
            exit_code = code

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
