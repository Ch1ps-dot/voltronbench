#!/bin/bash

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PFBENCH="$PROJECT_ROOT/benchmark"
PATH=$PATH:$PFBENCH/scripts/execution:$PFBENCH/scripts/analysis
NUM_CONTAINERS=$1
DURATION_MINUTES=${2:-1440}
TIMEOUT=$(( DURATION_MINUTES * 60))
SKIPCOUNT="${SKIPCOUNT:-1}"
TEST_TIMEOUT="${TEST_TIMEOUT:-20000}"
FORKED_DAAPD_STARTUP_WAIT_US="${FORKED_DAAPD_STARTUP_WAIT_US:-1000000}"
FORKED_DAAPD_MIN_TEST_TIMEOUT_MS="${FORKED_DAAPD_MIN_TEST_TIMEOUT_MS:-3000}"

export TARGET_LIST=$3
export FUZZER_LIST=$4

if [[ "x$NUM_CONTAINERS" == "x" ]] || [[ "x$TIMEOUT" == "x" ]] || [[ "x$TARGET_LIST" == "x" ]] || [[ "x$FUZZER_LIST" == "x" ]]
then
    echo "Usage: $0 NUM_CONTAINERS DURATION_MINUTES TARGET FUZZER"
    exit 1
fi

for timeout_setting in \
    TEST_TIMEOUT \
    FORKED_DAAPD_STARTUP_WAIT_US \
    FORKED_DAAPD_MIN_TEST_TIMEOUT_MS; do
    timeout_value=${!timeout_setting}
    if [[ ! "$timeout_value" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s must be a positive integer.\n' "$timeout_setting" >&2
        exit 1
    fi
done

FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE=$TEST_TIMEOUT
if (( FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE \
    < FORKED_DAAPD_MIN_TEST_TIMEOUT_MS )); then
    FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE=$FORKED_DAAPD_MIN_TEST_TIMEOUT_MS
fi
export FORKED_DAAPD_STARTUP_WAIT_US
export FORKED_DAAPD_MIN_TEST_TIMEOUT_MS
export FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE

CORE_PATTERN_PATH=/proc/sys/kernel/core_pattern
CORE_PATTERN_ORIGINAL=
CORE_PATTERN_CHANGED=0
RANDOMIZE_VA_SPACE_PATH=/proc/sys/kernel/randomize_va_space
RANDOMIZE_VA_SPACE_ORIGINAL=
RANDOMIZE_VA_SPACE_CHANGED=0
CHATAFL_EPHEMERAL_API_KEY_FILE=

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

    return 0
}

cleanup_run_environment() {
    local status=$?

    trap - EXIT
    if [[ -n "$CHATAFL_EPHEMERAL_API_KEY_FILE" ]]; then
        if ! rm -f -- "$CHATAFL_EPHEMERAL_API_KEY_FILE"; then
            echo "Warning: failed to remove the temporary ChatAFL API key." >&2
        fi
    fi
    restore_stateafl_kernel_settings || true
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

trap cleanup_run_environment EXIT
prepare_stateafl_kernel_settings

uses_chatafl=0
for fuzzer in ${FUZZER_LIST//,/ }; do
    if [[ "$fuzzer" == "chatafl" || "$fuzzer" == "all" ]]; then
        uses_chatafl=1
        break
    fi
done

uses_voltron=0
for fuzzer in ${FUZZER_LIST//,/ }; do
    if [[ "$fuzzer" == "voltron" || "$fuzzer" == "all" ]]; then
        uses_voltron=1
        break
    fi
done

CHATAFL_USE_API_GATEWAY=${CHATAFL_USE_API_GATEWAY:-1}
VOLTRON_USE_API_GATEWAY=${VOLTRON_USE_API_GATEWAY:-1}

validate_gateway_switch() {
    local name=$1
    local value=$2

    if [[ "$value" != "0" && "$value" != "1" ]]; then
        printf '%s must be either 0 or 1.\n' "$name" >&2
        exit 1
    fi
}

if [[ "$uses_chatafl" == "1" ]]; then
    validate_gateway_switch CHATAFL_USE_API_GATEWAY \
        "$CHATAFL_USE_API_GATEWAY"
    export CHATAFL_USE_API_GATEWAY
fi
if [[ "$uses_voltron" == "1" ]]; then
    validate_gateway_switch VOLTRON_USE_API_GATEWAY \
        "$VOLTRON_USE_API_GATEWAY"
    export VOLTRON_USE_API_GATEWAY
fi

uses_api_gateway=0
if [[ "$uses_chatafl" == "1" \
    && "$CHATAFL_USE_API_GATEWAY" == "1" ]] \
    || [[ "$uses_voltron" == "1" \
    && "$VOLTRON_USE_API_GATEWAY" == "1" ]]; then
    uses_api_gateway=1
    export VOLTRON_DOCKER_NETWORK="${VOLTRON_DOCKER_NETWORK:-voltronbench}"
    export VOLTRON_GATEWAY_BASE_URL="${VOLTRON_GATEWAY_BASE_URL:-http://voltron-api-gateway:8000/v1}"
    export VOLTRON_GATEWAY_TOKEN="${VOLTRON_GATEWAY_TOKEN:-voltronbench-internal}"
    export VOLTRON_GATEWAY_MODEL="${VOLTRON_GATEWAY_MODEL:-voltron-default}"
    if [[ "$VOLTRON_GATEWAY_TOKEN" == *$'\n'* \
        || "$VOLTRON_GATEWAY_TOKEN" == *$'\r'* ]]; then
        echo "VOLTRON_GATEWAY_TOKEN must not contain a newline." >&2
        exit 1
    fi
    LLM_GATEWAY_CONFIG_EFFECTIVE="${VOLTRON_GATEWAY_CONFIG:-$PROJECT_ROOT/config/voltron-llm.yaml}"
    if [[ ! -r "$LLM_GATEWAY_CONFIG_EFFECTIVE" ]]; then
        echo "Gateway configuration is not readable: $LLM_GATEWAY_CONFIG_EFFECTIVE" >&2
        exit 1
    fi
    LLM_GATEWAY_CONFIG_SHA256=$(
        sha256sum "$LLM_GATEWAY_CONFIG_EFFECTIVE" | cut -d ' ' -f 1
    )
    LLM_GATEWAY_PROFILE_MODELS=$(
        python3 "$PROJECT_ROOT/scripts/load_voltron_llm_config.py" \
            --models-only "$LLM_GATEWAY_CONFIG_EFFECTIVE"
    )
    export LLM_GATEWAY_CONFIG_SHA256
    export LLM_GATEWAY_PROFILE_MODELS
fi

write_chatafl_ephemeral_secret() {
    local secret_value=$1
    local file_prefix=$2
    local secret_root="$PROJECT_ROOT/.runtime/chatafl/secrets"

    if ! mkdir -p "$secret_root" || ! chmod 0700 "$secret_root"; then
        echo "Unable to prepare the ChatAFL secret directory." >&2
        exit 1
    fi
    if ! CHATAFL_EPHEMERAL_API_KEY_FILE=$(
        mktemp "$secret_root/${file_prefix}.XXXXXX"
    ); then
        echo "Unable to create the temporary ChatAFL secret file." >&2
        exit 1
    fi
    if ! chmod 0600 "$CHATAFL_EPHEMERAL_API_KEY_FILE" \
        || ! printf '%s' "$secret_value" \
            > "$CHATAFL_EPHEMERAL_API_KEY_FILE"; then
        echo "Unable to write the temporary ChatAFL secret file." >&2
        exit 1
    fi
    CHATAFL_API_KEY_FILE="$CHATAFL_EPHEMERAL_API_KEY_FILE"
}

prepare_chatafl_runtime_inputs() {
    CHATAFL_API_MODE=direct
    if [[ "$CHATAFL_USE_API_GATEWAY" == "1" ]]; then
        if [[ -n "${CHATAFL_MODEL:-}" \
            || -n "${CHATAFL_URL:-}" \
            || -n "${CHATAFL_API_KEY:-}" \
            || -n "${CHATAFL_API_KEY_FILE:-}" ]]; then
            echo "Direct ChatAFL API settings cannot be combined with gateway mode." >&2
            echo "Unset CHATAFL_MODEL, CHATAFL_URL, CHATAFL_API_KEY, and CHATAFL_API_KEY_FILE, or set CHATAFL_USE_API_GATEWAY=0." >&2
            exit 1
        fi
        CHATAFL_MODEL_EFFECTIVE="${CHATAFL_GATEWAY_MODEL:-$VOLTRON_GATEWAY_MODEL}"
        CHATAFL_URL_EFFECTIVE="${CHATAFL_GATEWAY_URL:-${VOLTRON_GATEWAY_BASE_URL%/}/chat/completions}"
        if [[ -n "${CHATAFL_DOCKER_NETWORK:-}" \
            && "$CHATAFL_DOCKER_NETWORK" != "$VOLTRON_DOCKER_NETWORK" ]]; then
            echo "CHATAFL_DOCKER_NETWORK must match VOLTRON_DOCKER_NETWORK in shared gateway mode." >&2
            exit 1
        fi
        CHATAFL_DOCKER_NETWORK="$VOLTRON_DOCKER_NETWORK"
        write_chatafl_ephemeral_secret \
            "$VOLTRON_GATEWAY_TOKEN" \
            gateway-token
        CHATAFL_API_KEY_SOURCE=gateway_internal_token
        CHATAFL_API_MODE=gateway
        export CHATAFL_DOCKER_NETWORK
        return
    fi

    if [[ "${CHATAFL_MODEL:-}" == *$'\n'* \
        || "${CHATAFL_MODEL:-}" == *$'\r'* ]]; then
        echo "CHATAFL_MODEL must not contain a newline." >&2
        exit 1
    fi
    if [[ "${CHATAFL_URL:-}" == *$'\n'* \
        || "${CHATAFL_URL:-}" == *$'\r'* ]]; then
        echo "CHATAFL_URL must not contain a newline." >&2
        exit 1
    fi
    if [[ -n "${CHATAFL_API_KEY:-}" \
        && -n "${CHATAFL_API_KEY_FILE:-}" ]]; then
        echo "Set only one of CHATAFL_API_KEY and CHATAFL_API_KEY_FILE." >&2
        exit 1
    fi

    CHATAFL_API_KEY_SOURCE=compiled_default
    if [[ -n "${CHATAFL_API_KEY_FILE:-}" ]]; then
        if [[ ! -f "$CHATAFL_API_KEY_FILE" \
            || ! -s "$CHATAFL_API_KEY_FILE" \
            || ! -r "$CHATAFL_API_KEY_FILE" ]]; then
            echo "ChatAFL API key file is empty or not readable." >&2
            exit 1
        fi
        CHATAFL_API_KEY_FILE=$(readlink -f "$CHATAFL_API_KEY_FILE")
        CHATAFL_API_KEY_MODE=$(stat -c '%a' "$CHATAFL_API_KEY_FILE")
        if (( (8#${CHATAFL_API_KEY_MODE} & 8#077) != 0 )); then
            echo "ChatAFL API key file must not be accessible by group or others." >&2
            exit 1
        fi
        CHATAFL_API_KEY_SOURCE=runtime_secret_file
    elif [[ -n "${CHATAFL_API_KEY:-}" ]]; then
        if [[ "$CHATAFL_API_KEY" == *$'\n'* \
            || "$CHATAFL_API_KEY" == *$'\r'* ]]; then
            echo "CHATAFL_API_KEY must not contain a newline." >&2
            exit 1
        fi
        write_chatafl_ephemeral_secret "$CHATAFL_API_KEY" api-key
        CHATAFL_API_KEY_SOURCE=runtime_ephemeral_secret
        unset CHATAFL_API_KEY
    fi
}

if [[ "$uses_chatafl" == "1" ]]; then
    prepare_chatafl_runtime_inputs
    export CHATAFL_API_MODE
fi

if [[ "$uses_api_gateway" == "1" ]]; then
    # Keep the StateAFL serialization lock owned by this top-level shell only.
    # Long-lived children must not inherit fd 9, otherwise an orphaned monitor
    # or gateway can block every later StateAFL run.
    "$PROJECT_ROOT/run_api_gateway.sh" start 9>&-
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

metadata_value() {
    local key=$1
    local metadata_file=$2

    awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$metadata_file"
}

if [[ "$uses_chatafl" == "1" ]]; then
    CHATAFL_BUILDER_IMAGE="${CHATAFL_BUILDER_IMAGE:-lightftp-vol}"
    if [[ -z "${CHATAFL_RUNTIME_BINARY:-}" ]]; then
        CHATAFL_RUNTIME_BINARY=$(
            "$PROJECT_ROOT/scripts/prepare_chatafl_runtime.sh" \
                "$CHATAFL_BUILDER_IMAGE"
        )
    fi
    if [[ ! -x "$CHATAFL_RUNTIME_BINARY" ]]; then
        echo "ChatAFL runtime binary is not executable: $CHATAFL_RUNTIME_BINARY" >&2
        exit 1
    fi

    CHATAFL_RUNTIME_METADATA="${CHATAFL_RUNTIME_BINARY%/*}/metadata.txt"
    CHATAFL_COMPILED_DEFAULT_MODEL=
    CHATAFL_COMPILED_DEFAULT_URL=
    CHATAFL_RUNTIME_SOURCE_SHA256=unknown
    CHATAFL_RUNTIME_BUILDER_IMAGE=custom
    CHATAFL_RUNTIME_BUILDER_IMAGE_ID=unknown
    if [[ -f "$CHATAFL_RUNTIME_METADATA" ]]; then
        CHATAFL_COMPILED_DEFAULT_MODEL=$(
            metadata_value compiled_default_model "$CHATAFL_RUNTIME_METADATA"
        )
        CHATAFL_COMPILED_DEFAULT_URL=$(
            metadata_value compiled_default_url "$CHATAFL_RUNTIME_METADATA"
        )
        CHATAFL_RUNTIME_SOURCE_SHA256=$(
            metadata_value runtime_source_sha256 "$CHATAFL_RUNTIME_METADATA"
        )
        CHATAFL_RUNTIME_BUILDER_IMAGE=$(
            metadata_value builder_image "$CHATAFL_RUNTIME_METADATA"
        )
        CHATAFL_RUNTIME_BUILDER_IMAGE_ID=$(
            metadata_value builder_image_id "$CHATAFL_RUNTIME_METADATA"
        )
    fi

    CHATAFL_MODEL_EFFECTIVE="${CHATAFL_MODEL_EFFECTIVE:-${CHATAFL_MODEL:-$CHATAFL_COMPILED_DEFAULT_MODEL}}"
    CHATAFL_URL_EFFECTIVE="${CHATAFL_URL_EFFECTIVE:-${CHATAFL_URL:-$CHATAFL_COMPILED_DEFAULT_URL}}"
    if [[ -z "$CHATAFL_MODEL_EFFECTIVE" ]]; then
        echo "Set CHATAFL_MODEL when using a custom ChatAFL runtime binary." >&2
        exit 1
    fi
    if [[ -z "$CHATAFL_URL_EFFECTIVE" ]]; then
        echo "Set CHATAFL_URL when using a custom ChatAFL runtime binary." >&2
        exit 1
    fi
    if [[ "$CHATAFL_MODEL_EFFECTIVE" == *$'\n'* \
        || "$CHATAFL_MODEL_EFFECTIVE" == *$'\r'* ]]; then
        echo "The effective ChatAFL model must not contain a newline." >&2
        exit 1
    fi
    if [[ "$CHATAFL_URL_EFFECTIVE" == *$'\n'* \
        || "$CHATAFL_URL_EFFECTIVE" == *$'\r'* ]]; then
        echo "The effective ChatAFL URL must not contain a newline." >&2
        exit 1
    fi
    CHATAFL_RUNTIME_BINARY_SHA256=$(
        sha256sum "$CHATAFL_RUNTIME_BINARY" | cut -d ' ' -f 1
    )
    export CHATAFL_RUNTIME_BINARY
    export CHATAFL_MODEL_EFFECTIVE
    export CHATAFL_URL_EFFECTIVE
    if [[ -n "${CHATAFL_API_KEY_FILE:-}" ]]; then
        export CHATAFL_API_KEY_FILE
    fi
fi

{
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'containers_per_target_fuzzer=%s\n' "$NUM_CONTAINERS"
    printf 'duration_minutes=%s\n' "$DURATION_MINUTES"
    printf 'targets=%s\n' "$TARGET_LIST"
    printf 'fuzzers=%s\n' "$FUZZER_LIST"
    printf 'skipcount=%s\n' "$SKIPCOUNT"
    printf 'test_timeout_ms=%s\n' "$TEST_TIMEOUT"
    printf 'forked_daapd_startup_wait_us=%s\n' \
        "$FORKED_DAAPD_STARTUP_WAIT_US"
    printf 'forked_daapd_min_test_timeout_ms=%s\n' \
        "$FORKED_DAAPD_MIN_TEST_TIMEOUT_MS"
    printf 'forked_daapd_test_timeout_ms_effective=%s\n' \
        "$FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE"
    printf 'raw_results_root=%s\n' "$RUN_ROOT"
    if [[ "$uses_chatafl" == "1" ]]; then
        printf 'chatafl_api_mode=%s\n' "$CHATAFL_API_MODE"
        printf 'chatafl_model=%s\n' "$CHATAFL_MODEL_EFFECTIVE"
        printf 'chatafl_url=%s\n' "$CHATAFL_URL_EFFECTIVE"
        printf 'chatafl_api_key_source=%s\n' "$CHATAFL_API_KEY_SOURCE"
        printf 'chatafl_runtime_binary_sha256=%s\n' \
            "$CHATAFL_RUNTIME_BINARY_SHA256"
        printf 'chatafl_runtime_source_sha256=%s\n' \
            "$CHATAFL_RUNTIME_SOURCE_SHA256"
        printf 'chatafl_runtime_builder_image=%s\n' \
            "$CHATAFL_RUNTIME_BUILDER_IMAGE"
        printf 'chatafl_runtime_builder_image_id=%s\n' \
            "$CHATAFL_RUNTIME_BUILDER_IMAGE_ID"
    fi
    if [[ "$uses_api_gateway" == "1" ]]; then
        printf 'llm_gateway_config_sha256=%s\n' \
            "$LLM_GATEWAY_CONFIG_SHA256"
        printf 'llm_gateway_profile_models=%s\n' \
            "$LLM_GATEWAY_PROFILE_MODELS"
    fi
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
scripts/execution/profuzzbench_exec_all.sh "$TARGET_LIST" "$FUZZER_LIST" 9>&-
EXPERIMENT_STATUS=$?
printf 'experiment_status=%s\n' "$EXPERIMENT_STATUS" >> "$PARAMETERS_FILE"

if [[ "$EXPERIMENT_STATUS" != "0" ]]; then
    echo "Experiment execution completed with status $EXPERIMENT_STATUS." >&2
    echo "Continuing with analysis and packaging of all available results." >&2
fi

BUNDLE_DIR="$PROJECT_ROOT/res_experiment_${RUN_ID}"
if ! mkdir "$BUNDLE_DIR"; then
    echo "Failed to create the experiment result bundle directory." >&2
    exit 1
fi

echo
echo "Starting automatic analysis."

ANALYSIS_STATUS=0
"$PROJECT_ROOT/analyze.sh" \
    "$TARGET_LIST" "$DURATION_MINUTES" "$BUNDLE_DIR" "$RUN_ROOT" 9>&- \
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
fi

if [[ "$EXPERIMENT_STATUS" != "0" ]]; then
    exit "$EXPERIMENT_STATUS"
fi
exit "$ANALYSIS_STATUS"
