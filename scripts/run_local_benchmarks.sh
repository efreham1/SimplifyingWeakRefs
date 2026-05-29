#!/usr/bin/env bash
# Runs weak reference GC benchmarks on the local machine (no SLURM).
#
# Usage:
#   ./scripts/run_local_benchmarks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export REPO_ROOT

export BENCHMARK_JVM_CORE_COUNT="${BENCHMARK_JVM_CORE_COUNT:-16}"
export BENCHMARK_AUX_CORE_COUNT="${BENCHMARK_AUX_CORE_COUNT:-2}"
export BENCHMARK_SELECTION="${BENCHMARK_SELECTION:-both}"
export OUTER_ITERATIONS="${OUTER_ITERATIONS:-50}"
export WARMUP_ITERATIONS="${WARMUP_ITERATIONS:-1}"
export COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-10}"
export PARALLEL_INSTANCES="${PARALLEL_INSTANCES:-1}"
export BENCHMARK_HEAP_SIZE="${BENCHMARK_HEAP_SIZE:-8g}"
export BENCHMARK_MULTI_REFERENCE_COUNT="${BENCHMARK_MULTI_REFERENCE_COUNT:-500000}"
export BENCHMARK_SINGLE_REFERENCE_COUNT="${BENCHMARK_SINGLE_REFERENCE_COUNT:-5000000}"
export BENCHMARK_VARIANTS="${BENCHMARK_VARIANTS:-none,clear_path_only,sep_only,dyn_only,clear_path_sep,clear_path_dyn,sep_dyn,all}"
export RUN_ID_PREFIX="${RUN_ID_PREFIX:-local-$(date +%Y%m%d-%H%M%S)}"
export FINAL_OUTPUT_ROOT="${FINAL_OUTPUT_ROOT:-${REPO_ROOT}/output}"

cd "$REPO_ROOT"

bash "${REPO_ROOT}/scripts/run_benchmark_iterations.sh" \
    --benchmark "$BENCHMARK_SELECTION" \
    --run-id-prefix "$RUN_ID_PREFIX" \
    --output-root "$FINAL_OUTPUT_ROOT" \
    --variant-image-root "${REPO_ROOT}/build/variant-images" \
    --heap-size "$BENCHMARK_HEAP_SIZE" \
    --multi-reference-count "$BENCHMARK_MULTI_REFERENCE_COUNT" \
    --single-reference-count "$BENCHMARK_SINGLE_REFERENCE_COUNT" \
    --outer "$OUTER_ITERATIONS" \
    --warmup "$WARMUP_ITERATIONS" \
    --cooldown "$COOLDOWN_SECONDS" \
    --parallel-instances "$PARALLEL_INSTANCES" \
    --jvm-core-count "$BENCHMARK_JVM_CORE_COUNT" \
    --aux-core-count "$BENCHMARK_AUX_CORE_COUNT"
