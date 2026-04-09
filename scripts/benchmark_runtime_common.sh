#!/usr/bin/env bash

if [ -n "${BENCHMARK_RUNTIME_COMMON_SH_LOADED:-}" ]; then
    return 0
fi
BENCHMARK_RUNTIME_COMMON_SH_LOADED=1

BENCHMARK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_REPO_ROOT="$(cd "${BENCHMARK_SCRIPT_DIR}/.." && pwd)"

benchmark_note() {
    printf '[benchmark] %s\n' "$*"
}

benchmark_warn() {
    printf '[benchmark] warning: %s\n' "$*" >&2
}

benchmark_fail() {
    printf '[benchmark] error: %s\n' "$*" >&2
    return 1
}

benchmark_require_command() {
    local command_name=$1

    command -v "$command_name" >/dev/null 2>&1 || benchmark_fail "required command not found: ${command_name}"
}

benchmark_get_allowed_cpu_list() {
    local cpu_list=""

    if [ -r /proc/self/status ]; then
        cpu_list="$(awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status)"
    fi

    if [ -z "$cpu_list" ] && command -v taskset >/dev/null 2>&1; then
        cpu_list="$(taskset -pc $$ 2>/dev/null | awk -F: 'NR == 1 { gsub(/[[:space:]]/, "", $2); print $2 }')"
    fi

    printf '%s\n' "$cpu_list"
}

benchmark_expand_cpu_list() {
    local cpu_list=$1
    local chunk
    local start
    local end
    local cpu

    [ -n "$cpu_list" ] || return 0

    IFS=',' read -r -a chunks <<< "$cpu_list"
    for chunk in "${chunks[@]}"; do
        chunk=${chunk//[[:space:]]/}
        [ -n "$chunk" ] || continue

        if [[ "$chunk" == *-* ]]; then
            start=${chunk%-*}
            end=${chunk#*-}

            if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
                benchmark_fail "invalid CPU range: ${chunk}"
                return 1
            fi

            if [ "$start" -gt "$end" ]; then
                benchmark_fail "CPU range start is greater than end: ${chunk}"
                return 1
            fi

            for ((cpu = start; cpu <= end; cpu++)); do
                printf '%s\n' "$cpu"
            done
        else
            if ! [[ "$chunk" =~ ^[0-9]+$ ]]; then
                benchmark_fail "invalid CPU index: ${chunk}"
                return 1
            fi
            printf '%s\n' "$chunk"
        fi
    done
}

benchmark_normalise_cpu_list() {
    local cpu_list=$1
    local -a cpus=()

    mapfile -t cpus < <(benchmark_expand_cpu_list "$cpu_list") || return 1
    if [ "${#cpus[@]}" -eq 0 ]; then
        benchmark_fail "CPU list resolves to zero CPUs"
        return 1
    fi

    (IFS=,; printf '%s\n' "${cpus[*]}")
}

benchmark_cpu_count() {
    local cpu_list=$1
    local -a cpus=()

    mapfile -t cpus < <(benchmark_expand_cpu_list "$cpu_list") || return 1
    printf '%s\n' "${#cpus[@]}"
}

benchmark_validate_cpu_subset() {
    local subset_list=$1
    local allowed_list=$2
    local -A allowed_map=()
    local cpu

    while IFS= read -r cpu; do
        allowed_map["$cpu"]=1
    done < <(benchmark_expand_cpu_list "$allowed_list")

    while IFS= read -r cpu; do
        if [ -z "${allowed_map[$cpu]:-}" ]; then
            benchmark_fail "CPU ${cpu} is outside the allowed CPU set ${allowed_list}"
            return 1
        fi
    done < <(benchmark_expand_cpu_list "$subset_list")
}

benchmark_validate_disjoint_cpu_lists() {
    local left_list=$1
    local right_list=$2
    local -A left_map=()
    local cpu

    while IFS= read -r cpu; do
        left_map["$cpu"]=1
    done < <(benchmark_expand_cpu_list "$left_list")

    while IFS= read -r cpu; do
        if [ -n "${left_map[$cpu]:-}" ]; then
            benchmark_fail "CPU ${cpu} appears in both CPU sets"
            return 1
        fi
    done < <(benchmark_expand_cpu_list "$right_list")
}

benchmark_has_affinity_configuration() {
    [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ] || \
        [ -n "${BENCHMARK_JVM_CORE_COUNT:-}" ] || [ -n "${BENCHMARK_AUX_CORE_COUNT:-}" ]
}

benchmark_ensure_allowed_core_set() {
    local allowed_list="${BENCHMARK_ALLOWED_CORE_SET:-}"

    if [ -z "$allowed_list" ]; then
        allowed_list="$(benchmark_get_allowed_cpu_list)"
    fi
    if [ -z "$allowed_list" ]; then
        benchmark_fail "unable to determine allowed CPU list"
        return 1
    fi

    allowed_list="$(benchmark_normalise_cpu_list "$allowed_list")" || return 1
    export BENCHMARK_ALLOWED_CORE_SET="$allowed_list"
}

benchmark_requested_affinity_summary() {
    local allowed_set="${BENCHMARK_ALLOWED_CORE_SET:-unset}"

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        printf 'requested jvm=%s aux=%s allowed=%s\n' \
            "${BENCHMARK_JVM_CORE_SET:-unset}" \
            "${BENCHMARK_AUX_CORE_SET:-unset}" \
            "$allowed_set"
    elif [ -n "${BENCHMARK_JVM_CORE_COUNT:-}" ] || [ -n "${BENCHMARK_AUX_CORE_COUNT:-}" ]; then
        printf 'requested per-instance jvm-count=%s aux-count=%s allowed=%s\n' \
            "${BENCHMARK_JVM_CORE_COUNT:-unset}" \
            "${BENCHMARK_AUX_CORE_COUNT:-unset}" \
            "$allowed_set"
    else
        printf 'affinity disabled\n'
    fi
}

benchmark_resolve_core_sets() {
    local allowed_list
    local allowed_count
    local jvm_core_count
    local aux_core_count
    local aux_start
    local -a allowed_cpus=()
    local -a jvm_cpus=()
    local -a aux_cpus=()

    benchmark_ensure_allowed_core_set || return 1
    allowed_list="${BENCHMARK_ALLOWED_CORE_SET}"
    allowed_count="$(benchmark_cpu_count "$allowed_list")" || return 1

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        if [ -z "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -z "${BENCHMARK_AUX_CORE_SET:-}" ]; then
            benchmark_fail "both BENCHMARK_JVM_CORE_SET and BENCHMARK_AUX_CORE_SET must be set together"
            return 1
        fi

        BENCHMARK_JVM_CORE_SET="$(benchmark_normalise_cpu_list "$BENCHMARK_JVM_CORE_SET")" || return 1
        BENCHMARK_AUX_CORE_SET="$(benchmark_normalise_cpu_list "$BENCHMARK_AUX_CORE_SET")" || return 1

        benchmark_validate_cpu_subset "$BENCHMARK_JVM_CORE_SET" "$allowed_list" || return 1
        benchmark_validate_cpu_subset "$BENCHMARK_AUX_CORE_SET" "$allowed_list" || return 1
        benchmark_validate_disjoint_cpu_lists "$BENCHMARK_JVM_CORE_SET" "$BENCHMARK_AUX_CORE_SET" || return 1
    else
        jvm_core_count=${BENCHMARK_JVM_CORE_COUNT:-}
        aux_core_count=${BENCHMARK_AUX_CORE_COUNT:-}

        if [ -z "$jvm_core_count" ] || [ -z "$aux_core_count" ]; then
            benchmark_fail "set BENCHMARK_JVM_CORE_COUNT and BENCHMARK_AUX_CORE_COUNT, or provide explicit CPU sets"
            return 1
        fi

        if ! [[ "$jvm_core_count" =~ ^[0-9]+$ && "$aux_core_count" =~ ^[0-9]+$ ]]; then
            benchmark_fail "CPU counts must be positive integers"
            return 1
        fi

        if [ "$jvm_core_count" -lt 1 ] || [ "$aux_core_count" -lt 1 ]; then
            benchmark_fail "CPU counts must be at least 1"
            return 1
        fi

        if [ $((jvm_core_count + aux_core_count)) -gt "$allowed_count" ]; then
            benchmark_fail "requested ${jvm_core_count} JVM CPUs and ${aux_core_count} auxiliary CPUs, but only ${allowed_count} CPUs are available (${allowed_list})"
            return 1
        fi

        mapfile -t allowed_cpus < <(benchmark_expand_cpu_list "$allowed_list")
        jvm_cpus=("${allowed_cpus[@]:0:jvm_core_count}")
        aux_start=$((allowed_count - aux_core_count))
        aux_cpus=("${allowed_cpus[@]:aux_start:aux_core_count}")

        BENCHMARK_JVM_CORE_SET="$(IFS=,; printf '%s' "${jvm_cpus[*]}")"
        BENCHMARK_AUX_CORE_SET="$(IFS=,; printf '%s' "${aux_cpus[*]}")"
    fi

    unset BENCHMARK_INSTANCE_ALLOWED_CORE_SET
    export BENCHMARK_ALLOWED_CORE_SET="$allowed_list"
    export BENCHMARK_JVM_CORE_SET
    export BENCHMARK_AUX_CORE_SET
}

benchmark_resolve_parallel_slot_core_sets() {
    local slot_index=$1
    local slot_count=$2
    local allowed_count
    local jvm_core_count
    local aux_core_count
    local per_slot_core_count
    local slot_start
    local -a allowed_cpus=()
    local -a slot_cpus=()
    local -a jvm_cpus=()
    local -a aux_cpus=()

    if [ "$slot_count" -lt 1 ] || [ "$slot_index" -lt 1 ] || [ "$slot_index" -gt "$slot_count" ]; then
        benchmark_fail "invalid parallel slot assignment ${slot_index}/${slot_count}"
        return 1
    fi

    benchmark_ensure_allowed_core_set || return 1
    allowed_count="$(benchmark_cpu_count "$BENCHMARK_ALLOWED_CORE_SET")" || return 1

    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ] || [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        benchmark_fail "parallel benchmark instances require BENCHMARK_JVM_CORE_COUNT and BENCHMARK_AUX_CORE_COUNT instead of explicit CPU sets"
        return 1
    fi

    jvm_core_count=${BENCHMARK_JVM_CORE_COUNT:-}
    aux_core_count=${BENCHMARK_AUX_CORE_COUNT:-}
    if [ -z "$jvm_core_count" ] || [ -z "$aux_core_count" ]; then
        benchmark_fail "parallel benchmark instances require BENCHMARK_JVM_CORE_COUNT and BENCHMARK_AUX_CORE_COUNT"
        return 1
    fi
    if ! [[ "$jvm_core_count" =~ ^[0-9]+$ && "$aux_core_count" =~ ^[0-9]+$ ]]; then
        benchmark_fail "CPU counts must be positive integers"
        return 1
    fi
    if [ "$jvm_core_count" -lt 1 ] || [ "$aux_core_count" -lt 1 ]; then
        benchmark_fail "CPU counts must be at least 1"
        return 1
    fi

    per_slot_core_count=$((jvm_core_count + aux_core_count))
    if [ $((slot_count * per_slot_core_count)) -gt "$allowed_count" ]; then
        benchmark_fail "requested ${slot_count} parallel instances with ${jvm_core_count} JVM CPUs and ${aux_core_count} auxiliary CPUs each, but only ${allowed_count} CPUs are available (${BENCHMARK_ALLOWED_CORE_SET})"
        return 1
    fi

    mapfile -t allowed_cpus < <(benchmark_expand_cpu_list "$BENCHMARK_ALLOWED_CORE_SET")
    slot_start=$(((slot_index - 1) * per_slot_core_count))
    slot_cpus=("${allowed_cpus[@]:slot_start:per_slot_core_count}")
    jvm_cpus=("${slot_cpus[@]:0:jvm_core_count}")
    aux_cpus=("${slot_cpus[@]:jvm_core_count:aux_core_count}")

    BENCHMARK_INSTANCE_ALLOWED_CORE_SET="$(IFS=,; printf '%s' "${slot_cpus[*]}")"
    BENCHMARK_JVM_CORE_SET="$(IFS=,; printf '%s' "${jvm_cpus[*]}")"
    BENCHMARK_AUX_CORE_SET="$(IFS=,; printf '%s' "${aux_cpus[*]}")"

    export BENCHMARK_INSTANCE_ALLOWED_CORE_SET
    export BENCHMARK_JVM_CORE_SET
    export BENCHMARK_AUX_CORE_SET
}

benchmark_affinity_summary() {
    local allowed_set="${BENCHMARK_INSTANCE_ALLOWED_CORE_SET:-${BENCHMARK_ALLOWED_CORE_SET:-unknown}}"

    if benchmark_has_affinity_configuration; then
        printf 'allowed=%s jvm=%s aux=%s\n' \
            "$allowed_set" \
            "${BENCHMARK_JVM_CORE_SET:-unset}" \
            "${BENCHMARK_AUX_CORE_SET:-unset}"
    else
        printf 'affinity disabled\n'
    fi
}

benchmark_pin_current_process_to_aux_cores() {
    [ -n "${BENCHMARK_AUX_CORE_SET:-}" ] || return 0
    taskset --cpu-list --pid "$BENCHMARK_AUX_CORE_SET" $$ >/dev/null
}

benchmark_run_on_jvm_cores() {
    if [ -n "${BENCHMARK_JVM_CORE_SET:-}" ]; then
        taskset --cpu-list "$BENCHMARK_JVM_CORE_SET" "$@"
    else
        "$@"
    fi
}

benchmark_run_on_aux_cores() {
    if [ -n "${BENCHMARK_AUX_CORE_SET:-}" ]; then
        taskset --cpu-list "$BENCHMARK_AUX_CORE_SET" "$@"
    else
        "$@"
    fi
}

benchmark_prepare_stage_dir() {
    local stage_root=$1
    local stage_label=$2
    local safe_label

    safe_label=${stage_label//[^A-Za-z0-9._-]/_}
    mkdir -p "$stage_root"
    BENCHMARK_STAGE_DIR="$(mktemp -d "${stage_root}/${safe_label}.XXXXXX")"
    BENCHMARK_STAGE_TMPDIR="${BENCHMARK_STAGE_DIR}/tmp"
    mkdir -p "$BENCHMARK_STAGE_TMPDIR"

    export BENCHMARK_STAGE_DIR
    export BENCHMARK_STAGE_TMPDIR
    export TMPDIR="$BENCHMARK_STAGE_TMPDIR"
    export TMP="$BENCHMARK_STAGE_TMPDIR"
    export TEMP="$BENCHMARK_STAGE_TMPDIR"

    printf '%s\n' "$BENCHMARK_STAGE_DIR"
}

benchmark_copy_stage_to_final() {
    local stage_dir=$1
    local final_dir=$2
    local entry
    local base_name

    mkdir -p "$final_dir"

    shopt -s dotglob nullglob
    for entry in "$stage_dir"/*; do
        base_name=$(basename "$entry")
        if [ "$base_name" = "tmp" ]; then
            continue
        fi
        cp -a "$entry" "$final_dir/"
    done
    shopt -u dotglob nullglob
}