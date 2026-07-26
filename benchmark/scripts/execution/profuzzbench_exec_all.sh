#!/bin/bash

export NUM_CONTAINERS="${NUM_CONTAINERS:-10}"
export TIMEOUT="${TIMEOUT:-86400}"
export SKIPCOUNT="${SKIPCOUNT:-1}"
export TEST_TIMEOUT="${TEST_TIMEOUT:-20000}"

TARGET_LIST="${1:-}"
FUZZER_LIST="${2:-}"

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
            echo "-P HTTP -D 200000 -m none -q 3 -s 3 -E -K -t ${TEST_TIMEOUT}+"
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
            echo "-u /home/ubuntu/experiments/lighttpd1/src/.libs/lighttpd"
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

    mkdir -p "$PFBENCH/$result_dir"
    profuzzbench_exec_common.sh \
        "$image" \
        "$NUM_CONTAINERS" \
        "$PFBENCH/$result_dir" \
        "$fuzzer" \
        "$out_dir" \
        "$options" \
        "$TIMEOUT" \
        "$SKIPCOUNT" &
}

run_voltron_target() {
    local target=$1
    local result_dir="results-${target}"
    local out_dir="out-${target}-voltron"

    mkdir -p "$PFBENCH/$result_dir"
    "$PFBENCH/../run_voltron.sh" \
        "${target}-vol" \
        "$NUM_CONTAINERS" \
        "$PFBENCH/$result_dir" \
        "$target" \
        "$out_dir" \
        "$TIMEOUT" \
        "$SKIPCOUNT" &
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

for fuzzer in $fuzzers; do
    if ! in_list "$fuzzer" "$SUPPORTED_FUZZERS"; then
        echo "Unsupported fuzzer: $fuzzer" >&2
        usage >&2
        exit 2
    fi
done

echo
echo "# NUM_CONTAINERS: ${NUM_CONTAINERS}"
echo "# TIMEOUT: ${TIMEOUT} s"
echo "# SKIPCOUNT: ${SKIPCOUNT}"
echo "# TEST TIMEOUT: ${TEST_TIMEOUT} ms"
echo "# TARGET LIST: ${targets}"
echo "# FUZZER LIST: ${fuzzers}"
echo

for fuzzer in $fuzzers; do
    for target in $targets; do
        echo
        echo "***** RUNNING $fuzzer ON $target *****"
        echo

        if [[ "$fuzzer" == "voltron" ]]; then
            run_voltron_target "$target"
        else
            run_standard_target "$target" "$fuzzer"
        fi
    done
done

wait
