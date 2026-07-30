#!/bin/bash

export NUM_CONTAINERS="${NUM_CONTAINERS:-10}"
export TIMEOUT="${TIMEOUT:-86400}"
export SKIPCOUNT="${SKIPCOUNT:-1}"
export TEST_TIMEOUT="${TEST_TIMEOUT:-20000}"
export FORKED_DAAPD_STARTUP_WAIT_US="${FORKED_DAAPD_STARTUP_WAIT_US:-1000000}"
export FORKED_DAAPD_MIN_TEST_TIMEOUT_MS="${FORKED_DAAPD_MIN_TEST_TIMEOUT_MS:-3000}"

for timeout_setting in \
    TEST_TIMEOUT \
    FORKED_DAAPD_STARTUP_WAIT_US \
    FORKED_DAAPD_MIN_TEST_TIMEOUT_MS; do
    timeout_value=${!timeout_setting}
    if [[ ! "$timeout_value" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s must be a positive integer.\n' "$timeout_setting" >&2
        exit 2
    fi
done

FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE=$TEST_TIMEOUT
if (( FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE \
    < FORKED_DAAPD_MIN_TEST_TIMEOUT_MS )); then
    FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE=$FORKED_DAAPD_MIN_TEST_TIMEOUT_MS
fi
export FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE

TARGET_LIST="${1:-}"
FUZZER_LIST="${2:-}"
RESULTS_ROOT="${RESULTS_ROOT:-$PFBENCH}"
source "$PFBENCH/scripts/execution/profuzzbench_monitor_common.sh"

SUPPORTED_TARGETS="live555 kamailio exim forked-daapd pure-ftpd proftpd bftpd lightftp lighttpd1"
SUPPORTED_FUZZERS="aflnet chatafl stateafl voltron"

usage() {
    echo "Usage: $0 TARGET FUZZER"
    echo "Targets: ${SUPPORTED_TARGETS} all"
    echo "Fuzzers: ${SUPPORTED_FUZZERS} all"
}

in_list() {
    local needle=$1
    local item

    for item in $2; do
        if [[ "$needle" == "$item" ]]; then
            return 0
        fi
    done
    return 1
}

target_options() {
    case "$1" in
        live555)
            echo "-P RTSP -D 10000 -q 3 -s 3 -E -K -R -m none"
            ;;
        kamailio)
            echo "-m none -P SIP -l 5061 -D 50000 -q 3 -s 3 -E -K -t ${TEST_TIMEOUT}+"
            ;;
        exim)
            echo "-P SMTP -D 10000 -q 3 -s 3 -E -K -W 100 -m none -t ${TEST_TIMEOUT}+"
            ;;
        forked-daapd)
            echo "-P HTTP -D ${FORKED_DAAPD_STARTUP_WAIT_US} -m none -q 3 -s 3 -E -K -t ${FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE}+"
            ;;
        pure-ftpd|proftpd|bftpd)
            echo "-m none -P FTP -D 10000 -q 3 -s 3 -E -K -t ${TEST_TIMEOUT}+"
            ;;
        lightftp)
            echo "-P FTP -D 10000 -q 3 -s 3 -E -K -m none -t ${TEST_TIMEOUT}+"
            ;;
        lighttpd1)
            echo "-P HTTP -D 200000 -m none -q 3 -s 3 -E -K -R -t ${TEST_TIMEOUT}+"
            ;;
    esac
}

stateafl_vanilla_options() {
    case "$1" in
        live555)
            echo "-u /home/ubuntu/experiments/live/testProgs/testOnDemandRTSPServer"
            ;;
        kamailio)
            echo "-u /home/ubuntu/experiments/kamailio/src/kamailio -U /home/ubuntu/experiments/kamailio/"
            ;;
        exim)
            echo "-u /home/ubuntu/experiments/exim/src/build-Linux-x86_64/exim"
            ;;
        forked-daapd)
            echo "-u /home/ubuntu/experiments/forked-daapd/src/forked-daapd"
            ;;
        pure-ftpd)
            echo "-u /home/ubuntu/experiments/pure-ftpd/src/pure-ftpd"
            ;;
        proftpd)
            echo "-u /home/ubuntu/experiments/proftpd/proftpd"
            ;;
        bftpd)
            echo "-u /home/ubuntu/experiments/bftpd/bftpd"
            ;;
        lightftp)
            echo "-u /home/ubuntu/experiments/LightFTP/Source/Release/fftp"
            ;;
        lighttpd1)
            echo "-u /home/ubuntu/experiments/lighttpd1-stateafl/src/lighttpd"
            ;;
    esac
}

run_standard_target() {
    local target=$1
    local fuzzer=$2
    local image="${target}-vol"
    local result_dir="results-${target}"
    local out_dir="out-${target}-${fuzzer}"
    local options

    options=$(target_options "$target")
    if [[ "$fuzzer" == "stateafl" ]]; then
        image="${target}-stateafl-vol"
        options="${options} $(stateafl_vanilla_options "$target")"
    fi

    mkdir -p "$RESULTS_ROOT/$result_dir"
    profuzzbench_exec_common.sh \
        "$image" \
        "$NUM_CONTAINERS" \
        "$RESULTS_ROOT/$result_dir" \
        "$fuzzer" \
        "$out_dir" \
        "$options" \
        "$TIMEOUT" \
        "$SKIPCOUNT"
}

run_voltron_target() {
    local target=$1
    local project_index=${2:-0}
    local result_dir="results-${target}"
    local out_dir="out-${target}-voltron"
    local launcher_log

    mkdir -p "$RESULTS_ROOT/$result_dir"
    launcher_log="$RESULTS_ROOT/$result_dir/voltron-launcher.log"
    if [[ "${PROFUZZBENCH_EXTERNAL_MONITOR:-0}" == "1" ]]; then
        exec env PROFUZZBENCH_PROJECT_INDEX="$project_index" \
            "$PFBENCH/../run_voltron.sh" \
            "${target}-vol" \
            "$NUM_CONTAINERS" \
            "$RESULTS_ROOT/$result_dir" \
            "$target" \
            "$out_dir" \
            "$TIMEOUT" \
            "$SKIPCOUNT" > "$launcher_log" 2>&1
    else
        exec env PROFUZZBENCH_PROJECT_INDEX="$project_index" \
            "$PFBENCH/../run_voltron.sh" \
            "${target}-vol" \
            "$NUM_CONTAINERS" \
            "$RESULTS_ROOT/$result_dir" \
            "$target" \
            "$out_dir" \
            "$TIMEOUT" \
            "$SKIPCOUNT"
    fi
}

if [[ -z "$TARGET_LIST" || -z "$FUZZER_LIST" ]]; then
    usage
    exit 1
fi

targets=${TARGET_LIST//,/ }
fuzzers=${FUZZER_LIST//,/ }

if [[ "$TARGET_LIST" == "all" ]]; then
    targets=$SUPPORTED_TARGETS
fi
if [[ "$FUZZER_LIST" == "all" ]]; then
    fuzzers=$SUPPORTED_FUZZERS
fi

for target in $targets; do
    if ! in_list "$target" "$SUPPORTED_TARGETS"; then
        echo "Unsupported target: $target" >&2
        usage >&2
        exit 2
    fi
done

job_pids=()
for fuzzer in $fuzzers; do
    if ! in_list "$fuzzer" "$SUPPORTED_FUZZERS"; then
        echo "Unsupported fuzzer: $fuzzer" >&2
        usage >&2
        exit 2
    fi
done

target_count=0
for _target in $targets; do
    target_count=$((target_count + 1))
done
fuzzer_count=0
for _fuzzer in $fuzzers; do
    fuzzer_count=$((fuzzer_count + 1))
done

CENTRAL_MONITOR_PID=
CENTRAL_VOLTRON_MONITOR=0
if [[ "$PROFUZZBENCH_MONITOR" != "0" \
    && "$target_count" -gt 1 \
    && "$fuzzer_count" -eq 1 \
    && "$fuzzers" == "voltron" ]]; then
    PROFUZZBENCH_RUN_ID=${PROFUZZBENCH_RUN_ID:-"voltron-$(date +%s)-$$"}
    PROFUZZBENCH_RUN_START_EPOCH=${PROFUZZBENCH_RUN_START_EPOCH:-$(date +%s)}
    PROFUZZBENCH_MONITOR_DOCKER_LABEL="voltronbench.run_id=${PROFUZZBENCH_RUN_ID}"
    PROFUZZBENCH_EXTERNAL_MONITOR=1
    export PROFUZZBENCH_RUN_ID
    export PROFUZZBENCH_RUN_START_EPOCH
    export PROFUZZBENCH_MONITOR_DOCKER_LABEL
    export PROFUZZBENCH_EXTERNAL_MONITOR
    CENTRAL_VOLTRON_MONITOR=1
fi

handle_execution_interrupt() {
    local job_pid

    trap - INT TERM
    echo
    echo "ProFuzzBench: interrupt received; stopping launchers and monitor."
    if [[ -n "$CENTRAL_MONITOR_PID" ]]; then
        profuzzbench_stop_monitor "$CENTRAL_MONITOR_PID"
        CENTRAL_MONITOR_PID=
    fi
    for job_pid in "${job_pids[@]}"; do
        if kill -0 "$job_pid" 2>/dev/null; then
            kill -TERM "$job_pid" 2>/dev/null || true
        fi
    done
    for job_pid in "${job_pids[@]}"; do
        wait "$job_pid" 2>/dev/null || true
    done
    if [[ "$CENTRAL_VOLTRON_MONITOR" == "1" ]]; then
        profuzzbench_print_final_container_summary \
            "voltron experiment ${PROFUZZBENCH_RUN_ID}" \
            "$TIMEOUT"
    fi
    echo "ProFuzzBench: interrupted; exiting with status 130."
    exit 130
}

trap handle_execution_interrupt INT TERM

echo
echo "# NUM_CONTAINERS: ${NUM_CONTAINERS}"
echo "# TIMEOUT: ${TIMEOUT} s"
echo "# SKIPCOUNT: ${SKIPCOUNT}"
echo "# TEST TIMEOUT: ${TEST_TIMEOUT} ms"
echo "# FORKED-DAAPD STARTUP WAIT: ${FORKED_DAAPD_STARTUP_WAIT_US} us"
echo "# FORKED-DAAPD TEST TIMEOUT: ${FORKED_DAAPD_TEST_TIMEOUT_MS_EFFECTIVE} ms"
echo "# TARGET LIST: ${targets}"
echo "# FUZZER LIST: ${fuzzers}"
echo "# RESULTS ROOT: ${RESULTS_ROOT}"
echo

project_index=0
for fuzzer in $fuzzers; do
    for target in $targets; do
        echo
        echo "***** RUNNING $fuzzer ON $target *****"
        echo

        if [[ "$fuzzer" == "voltron" ]]; then
            run_voltron_target "$target" "$project_index" &
        else
            run_standard_target "$target" "$fuzzer" &
        fi
        job_pids+=("$!")
        project_index=$((project_index + 1))
    done
done

if [[ "$CENTRAL_VOLTRON_MONITOR" == "1" ]]; then
    profuzzbench_monitor_containers \
        "voltron experiment ${PROFUZZBENCH_RUN_ID}" \
        "$TIMEOUT" &
    CENTRAL_MONITOR_PID=$!
fi

EXECUTION_STATUS=0
for job_pid in "${job_pids[@]}"; do
    if ! wait "$job_pid"; then
        EXECUTION_STATUS=1
    fi
done

if [[ "$CENTRAL_VOLTRON_MONITOR" == "1" ]]; then
    profuzzbench_stop_monitor "$CENTRAL_MONITOR_PID"
    profuzzbench_print_final_container_summary \
        "voltron experiment ${PROFUZZBENCH_RUN_ID}" \
        "$TIMEOUT"
fi

trap - INT TERM
exit "$EXECUTION_STATUS"
