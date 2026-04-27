#!/usr/bin/env python3
"""Export a single combined GC metric CSV from single and multi benchmark logs."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


OUTPUT_ROOT = Path("output")
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
FIELDNAMES = [
    "run_prefix",
    "run_id",
    "benchmark",
    "variant",
    "metric",
    "units",
    "sample_index",
    "total_avg",
    "total_max",
    "source_log",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run-prefix",
        required=True,
        help="Shared run prefix, e.g. slurm-5076215 or id_slurm-5076215",
    )
    parser.add_argument("--output-root", default=str(OUTPUT_ROOT), help="Benchmark output root directory")
    parser.add_argument(
        "--csv-dir",
        default=None,
        help="Output directory for combined CSV (default: results/variant_csv/<run-prefix>)",
    )
    parser.add_argument(
        "--csv-name",
        default=None,
        help="Combined CSV file name (default: combined_variants.csv)",
    )
    return parser.parse_args()


def normalize_run_prefix(run_prefix: str) -> str:
    return run_prefix[3:] if run_prefix.startswith("id_") else run_prefix


def get_mode_run_id(run_prefix: str, mode: str) -> str:
    return f"{run_prefix}-{mode}"


def get_run_output_dir(output_root: Path, run_id: str) -> Path:
    return output_root / f"id_{run_id}"


def collect_log_files(output_root: Path, run_id: str, variant: str, mode: str) -> list[Path]:
    benchmark_name = "field-single" if (variant == "weak_fields" and mode == "single") else "field" if variant == "weak_fields" else mode
    logs_dir = get_run_output_dir(output_root, run_id) / "logs"
    pattern = f"run_{benchmark_name}_{variant}_*_{run_id}.log"
    return sorted(logs_dir.glob(pattern), key=lambda p: p.name)


def parse_gc_stats_file(filename: Path) -> dict[str, dict[str, list[float] | str]]:
    metrics: dict[str, dict[str, list[float] | str]] = {}

    with filename.open(encoding="utf-8") as handle:
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

            value_pattern = r"(\d+\.?\d*)\s*/\s*(\d+\.?\d*)"
            matches = list(re.finditer(value_pattern, data))
            if len(matches) < 4:
                continue

            fourth_match = matches[3]
            total_avg = float(fourth_match.group(1))
            total_max = float(fourth_match.group(2))

            metric_start = re.search(r"\d", data)
            if not metric_start:
                continue
            metric_name = data[: metric_start.start()].strip()

            units_match = re.search(r"(\d+\.?\d*)\s*/\s*(\d+\.?\d*)\s+(\S+)\s*$", data)
            units = units_match.group(3) if units_match else ""

            if metric_name not in metrics:
                metrics[metric_name] = {"avg": [], "max": [], "units": units}
            metrics[metric_name]["avg"].append(total_avg)
            metrics[metric_name]["max"].append(total_max)

    return metrics


def collect_combined_rows(output_root: Path, run_prefix: str) -> list[dict[str, str | float | int]]:
    rows: list[dict[str, str | float | int]] = []

    for variant in VARIANTS_ORDERED:
        for mode in ("multi", "single"):
            run_id = get_mode_run_id(run_prefix, mode)
            log_files = collect_log_files(output_root, run_id, variant, mode)
            for log_file in log_files:
                metrics = parse_gc_stats_file(log_file)
                for metric_name, metric_data in metrics.items():
                    avg_values = metric_data["avg"]
                    max_values = metric_data["max"]
                    units = str(metric_data.get("units", ""))
                    for sample_index, (avg_value, max_value) in enumerate(zip(avg_values, max_values), start=1):
                        rows.append(
                            {
                                "run_prefix": run_prefix,
                                "run_id": run_id,
                                "benchmark": mode,
                                "variant": variant,
                                "metric": metric_name,
                                "units": units,
                                "sample_index": sample_index,
                                "total_avg": avg_value,
                                "total_max": max_value,
                                "source_log": log_file.name,
                            }
                        )

    return rows


def main() -> int:
    args = parse_args()
    output_root = Path(args.output_root)
    run_prefix = normalize_run_prefix(args.run_prefix)
    csv_dir = Path(args.csv_dir) if args.csv_dir else Path("results")

    rows = collect_combined_rows(output_root, run_prefix)
    if not rows:
        print("No rows found. Check that both run directories exist:")
        print(f"  {output_root / ('id_' + get_mode_run_id(run_prefix, 'multi'))}")
        print(f"  {output_root / ('id_' + get_mode_run_id(run_prefix, 'single'))}")
        return 1

    csv_dir.mkdir(parents=True, exist_ok=True)
    output_file = csv_dir / args.csv_name if args.csv_name else csv_dir / f"{run_prefix}_combined_variants.csv"
    with output_file.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {output_file} ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
