#!/bin/bash

set -u

TARGET=$1
RESULT_DIR=$2
SKIPCOUNT=${3:-1}
WORKDIR=${WORKDIR:-/home/ubuntu/experiments}
COVFILE="${RESULT_DIR}/cov_over_time.csv"
REPLAY_DIR="${RESULT_DIR}/replayable-queue"

write_empty_coverage() {
    printf 'Time,l_per,l_abs,b_per,b_abs\n' > "$COVFILE"
}

if [[ ! "$SKIPCOUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "VOLTRON coverage: invalid SKIPCOUNT: $SKIPCOUNT" >&2
    exit 2
fi

if ! command -v aflnet-replay > /dev/null 2>&1; then
    echo "VOLTRON coverage: aflnet-replay is unavailable" >&2
    exit 2
fi
if [[ ! -r /opt/voltron-target-cov-script.sh ]]; then
    echo "VOLTRON coverage: target cov_script is unavailable" >&2
    exit 2
fi

shopt -s nullglob
testcases=("$REPLAY_DIR"/id*)
if (( ${#testcases[@]} == 0 )); then
    echo "VOLTRON coverage: no replayable test cases were retained"
    write_empty_coverage
    exit 0
fi

case "$TARGET" in
    live555)
        COVERAGE_DIR="$WORKDIR/live-gcov/testProgs"
        PORT=8554
        ;;
    kamailio)
        COVERAGE_DIR="$WORKDIR"
        PORT=5061
        ;;
    exim)
        COVERAGE_DIR="$WORKDIR/exim-gcov"
        PORT=25
        pkill exim > /dev/null 2>&1 || true
        cp "$COVERAGE_DIR/src/build-Linux-x86_64/exim" /usr/exim/bin/exim
        ;;
    forked-daapd)
        COVERAGE_DIR="$WORKDIR"
        PORT=3689
        sudo /etc/init.d/dbus start > /dev/null 2>&1 || true
        sudo /etc/init.d/avahi-daemon start > /dev/null 2>&1 || true
        ;;
    pure-ftpd)
        COVERAGE_DIR="$WORKDIR/pure-ftpd-gcov"
        PORT=21
        ;;
    proftpd)
        COVERAGE_DIR="$WORKDIR/proftpd-gcov"
        PORT=21
        ;;
    bftpd)
        COVERAGE_DIR="$WORKDIR/bftpd-gcov"
        PORT=21
        ;;
    lightftp)
        COVERAGE_DIR="$WORKDIR/LightFTP-gcov/Source/Release"
        PORT=2200
        ;;
    lighttpd1)
        COVERAGE_DIR="$WORKDIR/lighttpd1-gcov"
        PORT=8080
        ;;
    *)
        echo "VOLTRON coverage: unsupported target: $TARGET" >&2
        exit 2
        ;;
esac

if [[ ! -d "$COVERAGE_DIR" ]]; then
    echo "VOLTRON coverage: missing gcov directory: $COVERAGE_DIR" >&2
    exit 2
fi

echo "VOLTRON coverage: replaying ${#testcases[@]} test cases for $TARGET"
cd "$COVERAGE_DIR"
if ! /bin/bash /opt/voltron-target-cov-script.sh \
    "$RESULT_DIR" "$PORT" "$SKIPCOUNT" "$COVFILE" 1; then
    echo "VOLTRON coverage: target coverage replay failed" >&2
    exit 1
fi

SANITIZED_COVFILE=$(mktemp "${RESULT_DIR}/.cov_over_time.XXXXXX")
if ! awk -F',' '
    BEGIN {
        print "Time,l_per,l_abs,b_per,b_abs"
    }
    NR > 1 &&
    $1 ~ /^[0-9]+$/ &&
    $2 ~ /^[0-9]+([.][0-9]+)?$/ &&
    $3 ~ /^[0-9]+$/ &&
    $4 ~ /^[0-9]+([.][0-9]+)?$/ &&
    $5 ~ /^[0-9]+$/ {
        found = 1
        print
    }
    END {
        exit(found ? 0 : 1)
    }
' "$COVFILE" > "$SANITIZED_COVFILE"; then
    rm -f "$SANITIZED_COVFILE"
    echo "VOLTRON coverage: cov_over_time.csv has no valid data rows" >&2
    exit 1
fi
mv "$SANITIZED_COVFILE" "$COVFILE"

echo "VOLTRON coverage: measurements saved to $COVFILE"
