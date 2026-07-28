#!/bin/bash

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PFBENCH="$PROJECT_ROOT/benchmark"
PATH=$PATH:$PFBENCH/scripts/execution:$PFBENCH/scripts/analysis
NUM_CONTAINERS=$1
DURATION_MINUTES=${2:-1440}
TIMEOUT=$(( DURATION_MINUTES * 60))
SKIPCOUNT="${SKIPCOUNT:-1}"
TEST_TIMEOUT="${TEST_TIMEOUT:-5000}"

export TARGET_LIST=$3
export FUZZER_LIST=$4

if [[ "x$NUM_CONTAINERS" == "x" ]] || [[ "x$TIMEOUT" == "x" ]] || [[ "x$TARGET_LIST" == "x" ]] || [[ "x$FUZZER_LIST" == "x" ]]
then
    echo "Usage: $0 NUM_CONTAINERS DURATION_MINUTES TARGET FUZZER"
    exit 1
fi

CORE_PATTERN_PATH=/proc/sys/kernel/core_pattern
CORE_PATTERN_ORIGINAL=
CORE_PATTERN_CHANGED=0
RANDOMIZE_VA_SPACE_PATH=/proc/sys/kernel/randomize_va_space
RANDOMIZE_VA_SPACE_ORIGINAL=
RANDOMIZE_VA_SPACE_CHANGED=0

write_kernel_setting() {
    local path=$1
    local value=$2

    if [[ -w "$path" ]]; then
        printf '%s\n' "$value" > "$path"
    elif command -v sudo > /dev/null 2>&1; then
        printf '%s\n' "$value" | sudo tee "$path" > /dev/null
    else
        echo "StateAFL requires root access to update $path." >&2
        return 1
    fi
}

restore_stateafl_kernel_settings() {
    local status=$?

    if [[ "$RANDOMIZE_VA_SPACE_CHANGED" == "1" ]]; then
        if write_kernel_setting \
            "$RANDOMIZE_VA_SPACE_PATH" \
            "$RANDOMIZE_VA_SPACE_ORIGINAL"; then
            echo "Restored $RANDOMIZE_VA_SPACE_PATH to its original value."
        else
            echo "Warning: failed to restore $RANDOMIZE_VA_SPACE_PATH." >&2
        fi
    fi

    if [[ "$CORE_PATTERN_CHANGED" == "1" ]]; then
        if write_kernel_setting "$CORE_PATTERN_PATH" "$CORE_PATTERN_ORIGINAL"; then
            echo "Restored $CORE_PATTERN_PATH to its original value."
        else
            echo "Warning: failed to restore $CORE_PATTERN_PATH." >&2
        fi
    fi

    return "$status"
}

prepare_stateafl_kernel_settings() {
    local fuzzer
    local uses_stateafl=0

    for fuzzer in ${FUZZER_LIST//,/ }; do
        if [[ "$fuzzer" == "stateafl" || "$fuzzer" == "all" ]]; then
            uses_stateafl=1
            break
        fi
    done

    if [[ "$uses_stateafl" != "1" ]]; then
        return
    fi

    # These settings are host-global. Serialize top-level StateAFL runs so one
    # invocation cannot restore the setting while another one is still active.
    exec 9>"/tmp/voltronbench-stateafl-kernel-settings.lock"
    flock 9

    for path in "$CORE_PATTERN_PATH" "$RANDOMIZE_VA_SPACE_PATH"; do
        if [[ ! -r "$path" ]]; then
            echo "Cannot read $path." >&2
            exit 1
        fi
    done

    trap restore_stateafl_kernel_settings EXIT
    CORE_PATTERN_ORIGINAL=$(<"$CORE_PATTERN_PATH")
    RANDOMIZE_VA_SPACE_ORIGINAL=$(<"$RANDOMIZE_VA_SPACE_PATH")

    if [[ "$CORE_PATTERN_ORIGINAL" != "core" ]]; then
        echo "Temporarily setting $CORE_PATTERN_PATH to core for StateAFL."
        if ! write_kernel_setting "$CORE_PATTERN_PATH" "core"; then
            echo "Failed to configure $CORE_PATTERN_PATH for StateAFL." >&2
            exit 1
        fi
        CORE_PATTERN_CHANGED=1
    else
        echo "$CORE_PATTERN_PATH is already set to core."
    fi

    if [[ "$RANDOMIZE_VA_SPACE_ORIGINAL" != "0" ]]; then
        echo "Temporarily disabling ASLR for StateAFL."
        if ! write_kernel_setting "$RANDOMIZE_VA_SPACE_PATH" "0"; then
            echo "Failed to disable ASLR for StateAFL." >&2
            exit 1
        fi
        RANDOMIZE_VA_SPACE_CHANGED=1
    else
        echo "ASLR is already disabled."
    fi

    if [[ "$(<"$CORE_PATTERN_PATH")" != "core" ]]; then
        echo "StateAFL preflight failed: $CORE_PATTERN_PATH is not core." >&2
        exit 1
    fi
    if [[ "$(<"$RANDOMIZE_VA_SPACE_PATH")" != "0" ]]; then
        echo "StateAFL preflight failed: ASLR is still enabled." >&2
        exit 1
    fi
}

prepare_stateafl_kernel_settings

uses_voltron=0
for fuzzer in ${FUZZER_LIST//,/ }; do
    if [[ "$fuzzer" == "voltron" || "$fuzzer" == "all" ]]; then
        uses_voltron=1
        break
    fi
done

if [[ "$uses_voltron" == "1" ]] \
    && [[ "${VOLTRON_USE_API_GATEWAY:-1}" == "1" ]]; then
    "$PROJECT_ROOT/run_api_gateway.sh" start
    export VOLTRON_USE_API_GATEWAY=1
    export VOLTRON_DOCKER_NETWORK="${VOLTRON_DOCKER_NETWORK:-voltronbench}"
    export VOLTRON_GATEWAY_BASE_URL="${VOLTRON_GATEWAY_BASE_URL:-http://voltron-api-gateway:8000/v1}"
    export VOLTRON_GATEWAY_TOKEN="${VOLTRON_GATEWAY_TOKEN:-voltronbench-internal}"
    export VOLTRON_GATEWAY_MODEL="${VOLTRON_GATEWAY_MODEL:-voltron-default}"
fi

RESULT_TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
RUNS_ROOT="$PFBENCH/experiment-runs"
if ! mkdir -p "$RUNS_ROOT"; then
    echo "Failed to create the experiment runs directory: $RUNS_ROOT" >&2
    exit 1
fi
RUN_ROOT=$(mktemp -d "$RUNS_ROOT/${RESULT_TIMESTAMP}_XXXXXX")
if [[ -z "$RUN_ROOT" || ! -d "$RUN_ROOT" ]]; then
    echo "Failed to create an isolated experiment result directory." >&2
    exit 1
fi
RUN_ID=$(basename "$RUN_ROOT")
PARAMETERS_FILE="$RUN_ROOT/experiment_parameters.txt"

{
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'containers_per_target_fuzzer=%s\n' "$NUM_CONTAINERS"
    printf 'duration_minutes=%s\n' "$DURATION_MINUTES"
    printf 'targets=%s\n' "$TARGET_LIST"
    printf 'fuzzers=%s\n' "$FUZZER_LIST"
    printf 'skipcount=%s\n' "$SKIPCOUNT"
    printf 'test_timeout_ms=%s\n' "$TEST_TIMEOUT"
    printf 'raw_results_root=%s\n' "$RUN_ROOT"
} > "$PARAMETERS_FILE"

echo
echo "Experiment run ID: $RUN_ID"
echo "Raw results directory: $RUN_ROOT"

cd "$PFBENCH"

PFBENCH=$PFBENCH \
RESULTS_ROOT=$RUN_ROOT \
PATH=$PATH \
NUM_CONTAINERS=$NUM_CONTAINERS \
TIMEOUT=$TIMEOUT \
SKIPCOUNT=$SKIPCOUNT \
TEST_TIMEOUT=$TEST_TIMEOUT \
scripts/execution/profuzzbench_exec_all.sh "$TARGET_LIST" "$FUZZER_LIST"
EXPERIMENT_STATUS=$?
printf 'experiment_status=%s\n' "$EXPERIMENT_STATUS" >> "$PARAMETERS_FILE"

if [[ "$EXPERIMENT_STATUS" != "0" ]]; then
    echo "Experiment execution failed with status $EXPERIMENT_STATUS; skipping analysis." >&2
    echo "Partial raw results are retained in: $RUN_ROOT" >&2
    exit "$EXPERIMENT_STATUS"
fi

BUNDLE_DIR="$PROJECT_ROOT/res_experiment_${RUN_ID}"
if ! mkdir "$BUNDLE_DIR"; then
    echo "Failed to create the experiment result bundle directory." >&2
    exit 1
fi

echo
echo "Experiment execution completed. Starting automatic analysis."

ANALYSIS_STATUS=0
"$PROJECT_ROOT/analyze.sh" \
    "$TARGET_LIST" "$DURATION_MINUTES" "$BUNDLE_DIR" "$RUN_ROOT" \
    || ANALYSIS_STATUS=$?
printf 'analysis_status=%s\n' "$ANALYSIS_STATUS" \
    >> "$PARAMETERS_FILE"
if ! cp "$PARAMETERS_FILE" "$BUNDLE_DIR/experiment_parameters.txt"; then
    echo "Failed to copy experiment parameters into the result bundle." >&2
    exit 1
fi

BUNDLE_NAME=$(basename "$BUNDLE_DIR")
BUNDLE_ARCHIVE="$PROJECT_ROOT/${BUNDLE_NAME}.tar.gz"
if ! tar -czf "$BUNDLE_ARCHIVE" -C "$PROJECT_ROOT" "$BUNDLE_NAME"; then
    echo "Failed to create the combined experiment archive." >&2
    exit 1
fi

echo
echo "All experiment results are packaged in:"
echo "  $BUNDLE_ARCHIVE"

if [[ "$ANALYSIS_STATUS" != "0" ]]; then
    echo "Warning: the archive was created, but one or more analyses failed." >&2
    exit "$ANALYSIS_STATUS"
fi
