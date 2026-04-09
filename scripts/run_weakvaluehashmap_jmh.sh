#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEBUG_LEVEL="release"
RESULT_ROOT="${REPO_ROOT}/output/weakvaluehashmap_jmh"
JMH_JAR_DIR="${JMH_JAR_DIR:-${REPO_ROOT}/build/jmh/jars}"
LIVE_SET="4096"
KEY_PAYLOAD_SIZE="64"
VALUE_PAYLOAD_SIZE="256"
LOOKUPS="32"
REPLACEMENTS="8"
RETIREMENTS="16"
WARMUP_ITERATIONS="3"
MEASUREMENT_ITERATIONS="5"
TIME_SECONDS="1"
FORKS="1"
THREADS="1"
BUILD_MISSING=true

while [ $# -gt 0 ]; do
  case "$1" in
    --debug-level)
      DEBUG_LEVEL="$2"
      shift 2
      ;;
    --result-root)
      RESULT_ROOT="$2"
      shift 2
      ;;
    --live-set)
      LIVE_SET="$2"
      shift 2
      ;;
    --key-payload-size)
      KEY_PAYLOAD_SIZE="$2"
      shift 2
      ;;
    --value-payload-size)
      VALUE_PAYLOAD_SIZE="$2"
      shift 2
      ;;
    --lookups)
      LOOKUPS="$2"
      shift 2
      ;;
    --replacements)
      REPLACEMENTS="$2"
      shift 2
      ;;
    --retirements)
      RETIREMENTS="$2"
      shift 2
      ;;
    --warmup)
      WARMUP_ITERATIONS="$2"
      shift 2
      ;;
    --measurement)
      MEASUREMENT_ITERATIONS="$2"
      shift 2
      ;;
    --time)
      TIME_SECONDS="$2"
      shift 2
      ;;
    --forks)
      FORKS="$2"
      shift 2
      ;;
    --threads)
      THREADS="$2"
      shift 2
      ;;
    --no-build)
      BUILD_MISSING=false
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

find_latest_jar() {
  local pattern="$1"
  local -a search_roots=()

  if [ -d "$JMH_JAR_DIR" ]; then
    search_roots+=("$JMH_JAR_DIR")
  fi
  if [ -d "${HOME}/.m2/repository" ]; then
    search_roots+=("${HOME}/.m2/repository")
  fi
  if [ -d "${HOME}/.gradle/caches/modules-2/files-2.1" ]; then
    search_roots+=("${HOME}/.gradle/caches/modules-2/files-2.1")
  fi

  if [ "${#search_roots[@]}" -eq 0 ]; then
    return 0
  fi

  find "${search_roots[@]}" -type f -name "$pattern" 2>/dev/null | LC_ALL=C sort | tail -1
}

JMH_CORE_JAR="$(find_latest_jar 'jmh-core-*.jar')"
JMH_GENERATOR_JAR="$(find_latest_jar 'jmh-generator-annprocess-*.jar')"
JOPT_SIMPLE_JAR="$(find_latest_jar 'jopt-simple-*.jar')"
COMMONS_MATH_JAR="$(find_latest_jar 'commons-math3-*.jar')"

for jar in "$JMH_CORE_JAR" "$JMH_GENERATOR_JAR" "$JOPT_SIMPLE_JAR" "$COMMONS_MATH_JAR"; do
  if [ -z "$jar" ] || [ ! -f "$jar" ]; then
    echo "Missing required JMH dependency jar. Run 'sh make/devkit/createJMHBundle.sh' to populate ${REPO_ROOT}/build/jmh/jars, or set JMH_JAR_DIR to a directory containing jmh-core, jmh-generator-annprocess, jopt-simple, and commons-math3 jars." >&2
    exit 1
  fi
done

JMH_RUNTIME_CP="${JMH_CORE_JAR}:${JOPT_SIMPLE_JAR}:${COMMONS_MATH_JAR}"
JMH_PROCESSOR_CP="${JMH_RUNTIME_CP}:${JMH_GENERATOR_JAR}"
VARIANT_SOURCE_ROOT="${REPO_ROOT}/test/weakrefs/weakvaluehashmap/org/openjdk/bench/weakvaluehashmap"
JMH_SOURCE_ROOT="${REPO_ROOT}/test/weakrefs/jmh/org/openjdk/bench/weakvaluehashmap"

variant_image_dir() {
  local variant="$1"
  printf '%s/build/variant-images/%s-linux-x86_64-server-%s/jdk/bin\n' "${REPO_ROOT}" "$variant" "$DEBUG_LEVEL"
}

ensure_variant() {
  local variant="$1"
  local java_bin

  java_bin="$(variant_image_dir "$variant")/java"
  if [ -x "$java_bin" ]; then
    return 0
  fi

  if [ "$BUILD_MISSING" = false ]; then
    echo "Missing variant JDK for ${variant}: ${java_bin}" >&2
    exit 1
  fi

  echo "Building missing variant image: ${variant}" >&2
  (cd "${REPO_ROOT}" && bash scripts/build_configs.sh --debug-level "$DEBUG_LEVEL" "$variant")

  if [ ! -x "$java_bin" ]; then
    echo "Variant JDK still missing after build: ${java_bin}" >&2
    exit 1
  fi
}

compile_benchmark() {
  local variant="$1"
  local benchmark_source="$2"
  shift 2
  local out_dir="${RESULT_ROOT}/classes/${variant}"
  local bin_dir

  bin_dir="$(variant_image_dir "$variant")"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  "${bin_dir}/javac" \
    -cp "$JMH_RUNTIME_CP" \
    -processorpath "$JMH_PROCESSOR_CP" \
    -d "$out_dir" \
    "$@" \
    "${JMH_SOURCE_ROOT}/WeakValueHashMapBenchmarkSupport.java" \
    "$benchmark_source"
}

run_benchmark() {
  local variant="$1"
  local benchmark_class="$2"
  local out_dir="${RESULT_ROOT}/classes/${variant}"
  local result_dir="${RESULT_ROOT}/results"
  local log_file="${result_dir}/${variant}.log"
  local csv_file="${result_dir}/${variant}.csv"
  local bin_dir

  bin_dir="$(variant_image_dir "$variant")"
  mkdir -p "$result_dir"

  "${bin_dir}/java" \
    -XX:+UseZGC \
    -cp "${out_dir}:${JMH_RUNTIME_CP}" \
    org.openjdk.jmh.Main "$benchmark_class" \
    -bm thrpt \
    -tu s \
    -wi "$WARMUP_ITERATIONS" \
    -i "$MEASUREMENT_ITERATIONS" \
    -w "${TIME_SECONDS}s" \
    -r "${TIME_SECONDS}s" \
    -f "$FORKS" \
    -t "$THREADS" \
    -foe true \
    -rf csv \
    -rff "$csv_file" \
    -p liveSet="$LIVE_SET" \
    -p keyPayloadSize="$KEY_PAYLOAD_SIZE" \
    -p valuePayloadSize="$VALUE_PAYLOAD_SIZE" \
    -p lookupsPerInvocation="$LOOKUPS" \
    -p replacementsPerInvocation="$REPLACEMENTS" \
    -p retirementsPerInvocation="$RETIREMENTS" | tee "$log_file"
}

print_summary() {
  local summary_file="${RESULT_ROOT}/results/summary.txt"
  : > "$summary_file"
  printf '%-14s %-72s %14s %s\n' "variant" "benchmark" "score" "unit" | tee -a "$summary_file"

  for csv in "${RESULT_ROOT}/results"/*.csv; do
    local variant
    variant="$(basename "$csv" .csv)"
    awk -F, -v variant="$variant" '
      NR == 1 {
        for (i = 1; i <= NF; i++) {
          gsub(/"/, "", $i)
          if ($i == "Benchmark") benchmark_col = i
          if ($i == "Score") score_col = i
          if ($i == "Unit" || $i == "Score Unit") unit_col = i
        }
        next
      }
      {
        gsub(/"/, "", $benchmark_col)
        gsub(/"/, "", $score_col)
        gsub(/"/, "", $unit_col)
        printf "%-14s %-72s %14s %s\n", variant, $benchmark_col, $score_col, $unit_col
      }
    ' "$csv" | tee -a "$summary_file"
  done
}

mkdir -p "$RESULT_ROOT"

ensure_variant none
ensure_variant all
ensure_variant weak_fields

compile_benchmark none \
  "${JMH_SOURCE_ROOT}/QueueWeakValueHashMapBenchmark.java" \
  "${VARIANT_SOURCE_ROOT}/WeakValueHashMapSupport.java" \
  "${VARIANT_SOURCE_ROOT}/QueueWeakValueHashMap.java"

compile_benchmark all \
  "${JMH_SOURCE_ROOT}/NoQueueWeakValueHashMapBenchmark.java" \
  "${VARIANT_SOURCE_ROOT}/WeakValueHashMapSupport.java" \
  "${VARIANT_SOURCE_ROOT}/NoQueueWeakValueHashMap.java"

compile_benchmark weak_fields \
  "${JMH_SOURCE_ROOT}/WeakFieldValueHashMapBenchmark.java" \
  "${VARIANT_SOURCE_ROOT}/WeakValueHashMapSupport.java" \
  "${VARIANT_SOURCE_ROOT}/WeakFieldValueHashMap.java"

run_benchmark none org.openjdk.bench.weakvaluehashmap.QueueWeakValueHashMapBenchmark
run_benchmark all org.openjdk.bench.weakvaluehashmap.NoQueueWeakValueHashMapBenchmark
run_benchmark weak_fields org.openjdk.bench.weakvaluehashmap.WeakFieldValueHashMapBenchmark

print_summary