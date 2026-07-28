#!/bin/bash

PFBENCH="$PWD/benchmark"
PATH=$PATH:$PFBENCH/scripts/execution:$PFBENCH/scripts/analysis
NUM_CONTAINERS=$1
TIMEOUT=$(( ${2:-1440} * 60))
SKIPCOUNT="${SKIPCOUNT:-1}"
TEST_TIMEOUT="${TEST_TIMEOUT:-5000}"

export TARGET_LIST=$3
export FUZZER_LIST=$4

if [[ "x$NUM_CONTAINERS" == "x" ]] || [[ "x$TIMEOUT" == "x" ]] || [[ "x$TARGET_LIST" == "x" ]] || [[ "x$FUZZER_LIST" == "x" ]]
then
    echo "Usage: $0 NUM_CONTAINERS TIMEOUT TARGET FUZZER"
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
    "$PWD/run_api_gateway.sh" start
    export VOLTRON_USE_API_GATEWAY=1
    export VOLTRON_DOCKER_NETWORK="${VOLTRON_DOCKER_NETWORK:-voltronbench}"
    export VOLTRON_GATEWAY_BASE_URL="${VOLTRON_GATEWAY_BASE_URL:-http://voltron-api-gateway:8000/v1}"
    export VOLTRON_GATEWAY_TOKEN="${VOLTRON_GATEWAY_TOKEN:-voltronbench-internal}"
    export VOLTRON_GATEWAY_MODEL="${VOLTRON_GATEWAY_MODEL:-voltron-default}"
fi

cd "$PFBENCH"

PFBENCH=$PFBENCH PATH=$PATH NUM_CONTAINERS=$NUM_CONTAINERS TIMEOUT=$TIMEOUT SKIPCOUNT=$SKIPCOUNT TEST_TIMEOUT=$TEST_TIMEOUT scripts/execution/profuzzbench_exec_all.sh "$TARGET_LIST" "$FUZZER_LIST"
