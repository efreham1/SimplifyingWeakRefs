#!/usr/bin/env python3
"""Plot weak-value hash map JMH comparison results."""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


VARIANT_ORDER = ("none", "all", "weak_fields")
VARIANT_LABELS = {
    "none": "Queue WeakRef Values",
    "all": "No-Queue WeakRef Values",
    "weak_fields": "Weak-Field Values",
}
VARIANT_COLOURS = {
    "none": "#4C78A8",
    "all": "#F58518",
    "weak_fields": "#54A24B",
}
BENCHMARK_ORDER = ("lookup", "replace", "cleanup", "mixed")
BENCHMARK_LABELS = {
    "lookup": "Lookup",
    "replace": "Replace",
    "cleanup": "Cleanup",
    "mixed": "Mixed",
}
PARAM_COLUMNS = {
    "liveSet": "Param: liveSet",
    "keyPayloadSize": "Param: keyPayloadSize",
    "valuePayloadSize": "Param: valuePayloadSize",
    "lookupsPerInvocation": "Param: lookupsPerInvocation",
    "replacementsPerInvocation": "Param: replacementsPerInvocation",
    "retirementsPerInvocation": "Param: retirementsPerInvocation",
}


@dataclass(frozen=True)
class BenchmarkResult:
    variant: str
    benchmark: str
    score: float
    error: float
    unit: str
    parameters: tuple[tuple[str, str], ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", default="output/weakvaluehashmap_jmh/results")
    parser.add_argument("--output-dir", default="output/weakvaluehashmap_jmh/plots")
    parser.add_argument("--baseline", default="none")
    parser.add_argument("--formats", nargs="+", default=["png"])
    return parser.parse_args()


def read_results(results_dir: Path) -> dict[tuple[tuple[str, str], ...], dict[str, dict[str, BenchmarkResult]]]:
    grouped: dict[tuple[tuple[str, str], ...], dict[str, dict[str, BenchmarkResult]]] = defaultdict(
        lambda: defaultdict(dict)
    )
    csv_files = sorted(results_dir.glob("*.csv"))
    if not csv_files:
        raise SystemExit(f"No CSV files found in {results_dir}")

    for csv_file in csv_files:
        variant = csv_file.stem
        with csv_file.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                benchmark = row["Benchmark"].rsplit(".", 1)[-1]
                parameters = tuple((key, row[column]) for key, column in PARAM_COLUMNS.items())
                result = BenchmarkResult(
                    variant=variant,
                    benchmark=benchmark,
                    score=float(row["Score"]),
                    error=float(row["Score Error (99.9%)"]),
                    unit=row["Unit"],
                    parameters=parameters,
                )
                grouped[parameters][variant][benchmark] = result
    return grouped


def ordered_variants(config_results: dict[str, dict[str, BenchmarkResult]]) -> list[str]:
    preferred = [variant for variant in VARIANT_ORDER if variant in config_results]
    extras = sorted(variant for variant in config_results if variant not in VARIANT_ORDER)
    return preferred + extras


def ordered_benchmarks(config_results: dict[str, dict[str, BenchmarkResult]]) -> list[str]:
    names = {benchmark for variant_results in config_results.values() for benchmark in variant_results}
    preferred = [benchmark for benchmark in BENCHMARK_ORDER if benchmark in names]
    extras = sorted(benchmark for benchmark in names if benchmark not in BENCHMARK_ORDER)
    return preferred + extras


def format_variant(variant: str) -> str:
    return VARIANT_LABELS.get(variant, variant.replace("_", " ").title())


def format_benchmark(benchmark: str) -> str:
    return BENCHMARK_LABELS.get(benchmark, benchmark.title())


def format_parameters(parameters: tuple[tuple[str, str], ...]) -> str:
    aliases = {
        "liveSet": "liveSet",
        "keyPayloadSize": "keyPayload",
        "valuePayloadSize": "valuePayload",
        "lookupsPerInvocation": "lookups",
        "replacementsPerInvocation": "replacements",
        "retirementsPerInvocation": "retirements",
    }
    return ", ".join(f"{aliases[key]}={value}" for key, value in parameters)


def slugify_parameters(parameters: tuple[tuple[str, str], ...]) -> str:
    aliases = {
        "liveSet": "ls",
        "keyPayloadSize": "kps",
        "valuePayloadSize": "vps",
        "lookupsPerInvocation": "lu",
        "replacementsPerInvocation": "rp",
        "retirementsPerInvocation": "rt",
    }
    return "_".join(f"{aliases[key]}{value}" for key, value in parameters)


def format_score(score: float) -> str:
    if score >= 1_000_000:
        return f"{score / 1_000_000:.2f}M"
    if score >= 1_000:
        return f"{score / 1_000:.1f}k"
    return f"{score:.0f}"


def format_ratio(ratio: float) -> str:
    if ratio >= 100:
        return f"{ratio:.0f}x"
    if ratio >= 10:
        return f"{ratio:.1f}x"
    return f"{ratio:.2f}x"


def annotate_bars(axis: plt.Axes, bars, labels: Iterable[str]) -> None:
    for bar, label in zip(bars, labels):
        height = bar.get_height()
        if height <= 0:
            continue
        axis.annotate(
            label,
            xy=(bar.get_x() + bar.get_width() / 2.0, height),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            va="bottom",
            rotation=90,
            fontsize=8,
        )


def plot_configuration(
    parameters: tuple[tuple[str, str], ...],
    config_results: dict[str, dict[str, BenchmarkResult]],
    output_dir: Path,
    formats: list[str],
    baseline: str,
) -> list[Path]:
    variants = ordered_variants(config_results)
    benchmarks = ordered_benchmarks(config_results)
    width = 0.8 / max(len(variants), 1)

    figure, axes = plt.subplots(2, 1, figsize=(13, 10), constrained_layout=True)

    for offset_index, variant in enumerate(variants):
        positions = [index + (offset_index - (len(variants) - 1) / 2.0) * width for index in range(len(benchmarks))]
        results = [config_results[variant][benchmark] for benchmark in benchmarks]
        bars = axes[0].bar(
            positions,
            [result.score for result in results],
            width=width,
            yerr=[result.error for result in results],
            capsize=4,
            color=VARIANT_COLOURS.get(variant, "#9D9DA1"),
            edgecolor="#2B2B2B",
            linewidth=0.6,
            label=format_variant(variant),
        )
        annotate_bars(axes[0], bars, [format_score(result.score) for result in results])

    axes[0].set_yscale("log")
    axes[0].set_ylabel("Throughput (ops/s)")
    axes[0].set_title("Absolute Throughput", loc="left", fontweight="bold")
    axes[0].grid(True, axis="y", which="both", alpha=0.25)
    axes[0].set_axisbelow(True)
    axes[0].legend(frameon=False, ncols=len(variants))

    comparison_variants = [variant for variant in variants if variant != baseline and baseline in config_results]
    width = 0.8 / max(len(comparison_variants), 1)
    for offset_index, variant in enumerate(comparison_variants):
        positions = [index + (offset_index - (len(comparison_variants) - 1) / 2.0) * width for index in range(len(benchmarks))]
        ratios = [config_results[variant][benchmark].score / config_results[baseline][benchmark].score for benchmark in benchmarks]
        bars = axes[1].bar(
            positions,
            ratios,
            width=width,
            color=VARIANT_COLOURS.get(variant, "#9D9DA1"),
            edgecolor="#2B2B2B",
            linewidth=0.6,
            label=format_variant(variant),
        )
        annotate_bars(axes[1], bars, [format_ratio(ratio) for ratio in ratios])

    axes[1].axhline(1.0, color="#2B2B2B", linewidth=1.0, linestyle="--")
    axes[1].set_yscale("log")
    axes[1].set_ylabel(f"Speedup vs {format_variant(baseline)}")
    axes[1].set_title("Relative Speedup", loc="left", fontweight="bold")
    axes[1].grid(True, axis="y", which="both", alpha=0.25)
    axes[1].set_axisbelow(True)
    axes[1].set_xticks(range(len(benchmarks)))
    axes[1].set_xticklabels([format_benchmark(benchmark) for benchmark in benchmarks])
    axes[0].set_xticks(range(len(benchmarks)))
    axes[0].set_xticklabels([])

    figure.suptitle(
        "Weak-Value HashMap JMH Comparison\n" + format_parameters(parameters),
        fontsize=15,
        fontweight="bold",
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    base_name = f"weakvaluehashmap_jmh_comparison_{slugify_parameters(parameters)}"
    written = []
    for fmt in formats:
        output_file = output_dir / f"{base_name}.{fmt}"
        figure.savefig(output_file, dpi=200, bbox_inches="tight")
        written.append(output_file)
    plt.close(figure)
    return written


def main() -> int:
    args = parse_args()
    grouped = read_results(Path(args.results_dir))
    written = []
    for parameters, config_results in sorted(grouped.items()):
        written.extend(plot_configuration(parameters, config_results, Path(args.output_dir), args.formats, args.baseline))
    for output_file in written:
        print(f"Wrote {output_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())