#!/usr/bin/env python3
"""Export combined GC metric and memory CSVs from benchmark logs."""

from __future__ import annotations

import argparse
import csv
import json
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
GC_FIELDNAMES = [
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

MEMORY_FIELDNAMES = [
    "run_prefix",
    "run_id",
    "benchmark",
    "variant",
    "timestamp_ms",
    "rss_kb",
    "gc_reserved_kb",
    "gc_committed_kb",
    "heap_kb",
    "phase",
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
    return parser.parse_args()


def normalize_run_prefix(run_prefix: str) -> str:
    return run_prefix[3:] if run_prefix.startswith("id_") else run_prefix


def get_mode_run_id(run_prefix: str, mode: str) -> str:
    return f"{run_prefix}-{mode}"


def get_run_output_dir(output_root: Path, run_id: str) -> Path:
    return output_root / f"id_{run_id}"


def _benchmark_name(variant: str, mode: str) -> str:
    if variant == "weak_fields" and mode == "single":
        return "field-single"
    if variant == "weak_fields":
        return "field"
    return mode


def collect_log_files(output_root: Path, run_id: str, variant: str, mode: str) -> list[Path]:
    bname = _benchmark_name(variant, mode)
    logs_dir = get_run_output_dir(output_root, run_id) / "logs"
    pattern = f"run_{bname}_{variant}_*_{run_id}.log"
    return sorted(logs_dir.glob(pattern), key=lambda p: p.name)


def collect_memory_files(output_root: Path, run_id: str, variant: str, mode: str) -> list[Path]:
    bname = _benchmark_name(variant, mode)
    memory_dir = get_run_output_dir(output_root, run_id) / "memory"
    pattern = f"monitor_{bname}_{variant}_*_{run_id}.csv"
    return sorted(memory_dir.glob(pattern), key=lambda p: p.name)


MEMORY_COLUMNS = ("rss_kb", "gc_reserved_kb", "gc_committed_kb", "heap_kb")


def parse_memory_file(filename: Path) -> list[dict[str, str]]:
    """Return one row per timestamp (wide format) from a memory monitor CSV."""
    rows: list[dict[str, str]] = []
    with filename.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.startswith("[monitor_data]"):
                continue
            data = line[len("[monitor_data]"):].strip()
            parts = data.split(",")
            # fields: timestamp_ms, rss_kb, gc_reserved_kb, gc_committed_kb, heap_kb, phase
            if len(parts) < 5:
                continue
            rows.append({
                "timestamp_ms": parts[0].strip(),
                "rss_kb": parts[1].strip(),
                "gc_reserved_kb": parts[2].strip(),
                "gc_committed_kb": parts[3].strip(),
                "heap_kb": parts[4].strip(),
                "phase": parts[5].strip() if len(parts) > 5 else "",
            })
    return rows


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


def parse_log_config(filename: Path) -> dict[str, str]:
    args_value = ""
    command_value = ""
    jvm_core_count = ""
    aux_core_count = ""
    outer_iterations = ""
    warmup_iterations = ""
    cooldown_seconds = ""

    with filename.open(encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped.startswith("Args:"):
                args_value = stripped.partition(":")[2].strip()
            elif stripped.startswith("Command:"):
                command_value = stripped.partition(":")[2].strip()
            elif stripped.startswith("JVM_CORE_COUNT:"):
                jvm_core_count = stripped.partition(":")[2].strip()
            elif stripped.startswith("AUX_CORE_COUNT:"):
                aux_core_count = stripped.partition(":")[2].strip()
            elif stripped.startswith("OUTER_ITERATIONS:"):
                outer_iterations = stripped.partition(":")[2].strip()
            elif stripped.startswith("WARMUP_ITERATIONS:"):
                warmup_iterations = stripped.partition(":")[2].strip()
            elif stripped.startswith("COOLDOWN_SECONDS:"):
                cooldown_seconds = stripped.partition(":")[2].strip()

            if all([args_value, command_value, jvm_core_count, aux_core_count,
                    outer_iterations, warmup_iterations, cooldown_seconds]):
                break

    # Fallback: parse iteration count from the run header line for older logs
    if not outer_iterations:
        with filename.open(encoding="utf-8") as handle:
            for line in handle:
                m = re.search(r"outer iteration \d+/(\d+)", line)
                if m:
                    outer_iterations = m.group(1)
                    break

    xms_match = re.search(r"(?:^|\s)-Xms(\S+)", command_value)
    xmx_match = re.search(r"(?:^|\s)-Xmx(\S+)", command_value)
    benchmark_class = ""
    for token in command_value.split():
        if token.endswith(".java"):
            benchmark_class = Path(token).name
            break

    return {
        "benchmark_args": args_value,
        "heap_xms": xms_match.group(1) if xms_match else "",
        "heap_xmx": xmx_match.group(1) if xmx_match else "",
        "benchmark_class": benchmark_class,
        "java_command": command_value,
        "jvm_core_count": jvm_core_count,
        "aux_core_count": aux_core_count,
        "outer_iterations": outer_iterations,
        "warmup_iterations": warmup_iterations,
        "cooldown_seconds": cooldown_seconds,
    }


def collect_gc_rows(
    output_root: Path, run_prefix: str
) -> tuple[list[dict], dict[str, dict[str, str]]]:
    rows: list[dict] = []
    mode_config: dict[str, dict[str, str]] = {}

    for variant in VARIANTS_ORDERED:
        for mode in ("multi", "single"):
            run_id = get_mode_run_id(run_prefix, mode)
            for log_file in collect_log_files(output_root, run_id, variant, mode):
                if mode not in mode_config:
                    mode_config[mode] = parse_log_config(log_file)
                metrics = parse_gc_stats_file(log_file)
                for metric_name, metric_data in metrics.items():
                    units = str(metric_data.get("units", ""))
                    for sample_index, (avg_value, max_value) in enumerate(
                        zip(metric_data["avg"], metric_data["max"]), start=1
                    ):
                        rows.append({
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
                        })
    return rows, mode_config


def collect_memory_rows(output_root: Path, run_prefix: str) -> list[dict]:
    rows: list[dict] = []

    for variant in VARIANTS_ORDERED:
        for mode in ("multi", "single"):
            run_id = get_mode_run_id(run_prefix, mode)
            for mem_file in collect_memory_files(output_root, run_id, variant, mode):
                for mem_row in parse_memory_file(mem_file):
                    rows.append({
                        "run_prefix": run_prefix,
                        "run_id": run_id,
                        "benchmark": mode,
                        "variant": variant,
                        **mem_row,
                        "source_log": mem_file.name,
                    })
    return rows


def main() -> int:
    args = parse_args()
    output_root = Path(args.output_root)
    run_prefix = normalize_run_prefix(args.run_prefix)
    csv_dir = Path(args.csv_dir) if args.csv_dir else Path("results")

    gc_rows, mode_config = collect_gc_rows(output_root, run_prefix)
    mem_rows = collect_memory_rows(output_root, run_prefix)

    if not gc_rows and not mem_rows:
        print("No rows found. Check that both run directories exist:")
        print(f"  {output_root / ('id_' + get_mode_run_id(run_prefix, 'multi'))}")
        print(f"  {output_root / ('id_' + get_mode_run_id(run_prefix, 'single'))}")
        return 1

    csv_dir.mkdir(parents=True, exist_ok=True)

    gc_file = csv_dir / f"{run_prefix}_combined_gc.csv"
    with gc_file.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=GC_FIELDNAMES)
        writer.writeheader()
        writer.writerows(gc_rows)
    print(f"Wrote {gc_file} ({len(gc_rows)} rows)")

    mem_file = csv_dir / f"{run_prefix}_combined_memory.csv"
    with mem_file.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=MEMORY_FIELDNAMES)
        writer.writeheader()
        writer.writerows(mem_rows)
    print(f"Wrote {mem_file} ({len(mem_rows)} rows)")

    config_file = csv_dir / "configs.json"
    all_configs: dict = {}
    if config_file.exists():
        with config_file.open(encoding="utf-8") as handle:
            all_configs = json.load(handle)
    all_configs[run_prefix] = mode_config
    with config_file.open("w", encoding="utf-8") as handle:
        json.dump(all_configs, handle, indent=2)
    print(f"Updated {config_file}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
