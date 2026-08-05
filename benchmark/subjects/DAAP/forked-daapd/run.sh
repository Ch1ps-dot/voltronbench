#!/bin/bash

FUZZER=$1     #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
OUTDIR=$2     #name of the output folder
OPTIONS=$3    #all configured options -- to make it flexible, we only fix some options (e.g., -i, -o, -N) in this script
TIMEOUT=$4    #time for fuzzing
SKIPCOUNT=$5  #used for calculating cov over time. e.g., SKIPCOUNT=5 means we run gcovr after every 5 test cases
OUTPUT_PATH="${WORKDIR}/${OUTDIR}"
DIAGNOSTICS_DIR="${WORKDIR}/${OUTDIR}.diagnostics"
RUN_STATUS_LOG="${DIAGNOSTICS_DIR}/run-status.txt"
PREFLIGHT_LOG="${DIAGNOSTICS_DIR}/target-preflight.log"

record_run_status() {
  mkdir -p "$DIAGNOSTICS_DIR"
  printf '%s=%s\n' "$1" "$2" >> "$RUN_STATUS_LOG"
}

persist_diagnostics() {
  local destination="${OUTPUT_PATH}/diagnostics"

  mkdir -p "$destination"
  if [[ -d "$DIAGNOSTICS_DIR" ]]; then
    cp -a "$DIAGNOSTICS_DIR"/. "$destination"/
    rm -rf "$DIAGNOSTICS_DIR"
  fi
}

archive_preflight_failure() {
  mkdir -p "$OUTPUT_PATH"
  persist_diagnostics
  cd "$WORKDIR" || return 1
  tar -zcf "${WORKDIR}/${OUTDIR}.tar.gz" "$OUTDIR"
}

validate_stateafl_initial_seeds() {
  local expected_seed_count
  local replayed_seed_count
  local validation_log="${OUTPUT_PATH}/diagnostics/stateafl-initial-seeds.txt"

  expected_seed_count=$(find "$INPUTS" -mindepth 1 -maxdepth 1 -type f | wc -l)
  replayed_seed_count=$(
    find "$OUTPUT_PATH/replayable-queue" -mindepth 1 -maxdepth 1 \
      -type f -name '*orig:*' | wc -l
  )
  {
    printf 'expected_initial_seeds=%s\n' "$expected_seed_count"
    printf 'replayed_initial_seeds=%s\n' "$replayed_seed_count"
    if [[ -f "$OUTPUT_PATH/fuzzer_stats" ]]; then
      awk -F ' *: *' \
        '$1 == "start_time" || $1 == "last_update" ||
         $1 == "execs_done" || $1 == "execs_per_sec" ||
         $1 == "paths_total" || $1 == "exec_timeout" {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
          print $1 "=" $2
        }' "$OUTPUT_PATH/fuzzer_stats"
    fi
  } > "$validation_log"

  if [[ "$expected_seed_count" -eq 0 \
      || "$replayed_seed_count" -ne "$expected_seed_count" ]]; then
    printf 'initial_seed_validation=failed\n' >> "$validation_log"
    echo "ERROR: StateAFL calibrated ${replayed_seed_count}/${expected_seed_count} forked-daapd initial seeds." >&2
    return 1
  fi

  printf 'initial_seed_validation=passed\n' >> "$validation_log"
}

strstr() {
  [ "${1#*$2*}" = "$1" ] && return 1
  return 0
}

#Network deamons needed by forked-daapd
sudo /etc/init.d/dbus start
sudo /etc/init.d/avahi-daemon start

sudo /etc/init.d/dbus status
if [ $? -ne 0 ]
then
  echo "Unable to run DBUS"
  exit 1
fi

sudo /etc/init.d/avahi-daemon status
if [ $? -ne 0 ]
then
  echo "Unable to run AVAHI daemon"
  exit 1
fi

record_run_status run_started_at "$(date --iso-8601=seconds)"
record_run_status fuzzer "$FUZZER"
record_run_status duration_seconds "$TIMEOUT"

#Commands for afl-based fuzzers (e.g., aflnet, aflnwe)
if $(strstr $FUZZER "afl") || $(strstr $FUZZER "llm"); then

  # Run fuzzer-specific commands (if any)
  if [ -e ${WORKDIR}/run-${FUZZER} ]; then
    source ${WORKDIR}/run-${FUZZER}
  fi

  TARGET_DIR=${TARGET_DIR:-"forked-daapd"}
  INPUTS=${INPUTS:-${WORKDIR}"/in-daap"}

  TARGET_BINARY="${WORKDIR}/${TARGET_DIR}/src/forked-daapd"
  if [ ! -x "$TARGET_BINARY" ]; then
    echo "ERROR: forked-daapd target binary is missing or not executable: $TARGET_BINARY" >&2
    exit 2
  fi
  if [ "$FUZZER" = "stateafl" ]; then
    if [ -z "${STATEAFL_TARGET_BINARY:-}" ]; then
      echo "ERROR: StateAFL target binary was not configured by run-stateafl." >&2
      exit 2
    fi
    if [ ! -x "$STATEAFL_TARGET_BINARY" ]; then
      echo "ERROR: StateAFL target binary is missing or not executable: $STATEAFL_TARGET_BINARY" >&2
      exit 2
    fi
    if [[ "$TIMEOUT" -lt 300 ]]; then
      echo "WARNING: forked-daapd StateAFL runs shorter than 300 seconds may end during initial calibration." >&2
      record_run_status short_budget_warning true
    else
      record_run_status short_budget_warning false
    fi
    record_run_status preflight_started_at "$(date --iso-8601=seconds)"
    bash "${WORKDIR}/forked-daapd-preflight" \
      "$TARGET_BINARY" "${WORKDIR}/forked-daapd.conf" "$PREFLIGHT_LOG"
    preflight_status=$?
    if [[ "$preflight_status" -ne 0 ]]; then
      record_run_status preflight_status failed
      record_run_status preflight_exit_status "$preflight_status"
      archive_preflight_failure
      echo "ERROR: forked-daapd target preflight failed; skipping StateAFL." >&2
      exit 3
    fi
    record_run_status preflight_status passed
  fi

  #Step-1. Do Fuzzing
  #Move to fuzzing folder
  cd $WORKDIR

  record_run_status fuzz_started_at "$(date --iso-8601=seconds)"
  timeout -k 2s --preserve-status $TIMEOUT /home/ubuntu/${FUZZER}/afl-fuzz -d -i ${INPUTS} -o $OUTDIR -N tcp://127.0.0.1/3689 $OPTIONS "$TARGET_BINARY" -d 0 -c ${WORKDIR}/forked-daapd.conf -f

  STATUS=$?
  record_run_status fuzz_finished_at "$(date --iso-8601=seconds)"
  record_run_status fuzz_exit_status "$STATUS"

  if [ ! -d "$OUTPUT_PATH" ]; then
    echo "ERROR: Fuzzer exited without creating its output directory: $OUTPUT_PATH" >&2
    record_run_status fuzzer_output_status missing
    archive_preflight_failure
    if [ "$STATUS" -eq 0 ]; then
      STATUS=1
    fi
    exit "$STATUS"
  fi

  record_run_status fuzzer_output_status present
  persist_diagnostics

  if [ "$FUZZER" = "stateafl" ] && [ ! -d "$OUTPUT_PATH/replayable-queue" ]; then
    echo "ERROR: StateAFL output is missing replayable-queue; skipping coverage replay." >&2
    tar -zcvf "${WORKDIR}/${OUTDIR}.tar.gz" "$OUTDIR"
    if [ "$STATUS" -eq 0 ]; then
      STATUS=1
    fi
    exit "$STATUS"
  fi

  if [ "$FUZZER" = "stateafl" ]; then
    if ! validate_stateafl_initial_seeds; then
      STATUS=1
    fi
  fi

  #Step-2. Collect code coverage over time
  #Move to gcov folder
  cd $WORKDIR

  #The last argument passed to cov_script should be 0 if the fuzzer is afl/nwe and it should be 1 if the fuzzer is based on aflnet
  #0: the test case is a concatenated message sequence -- there is no message boundary
  #1: the test case is a structured file keeping several request messages
  if [ $FUZZER = "aflnwe" ]; then
    cov_script ${WORKDIR}/${OUTDIR}/ 3689 ${SKIPCOUNT} ${WORKDIR}/${OUTDIR}/cov_over_time.csv 0
  else
    cov_script ${WORKDIR}/${OUTDIR}/ 3689 ${SKIPCOUNT} ${WORKDIR}/${OUTDIR}/cov_over_time.csv 1
  fi

  cd $WORKDIR/forked-daapd-gcov
  gcovr -r . --html --html-details -o index.html
  mkdir -p ${WORKDIR}/${OUTDIR}/cov_html/
  cp *.html ${WORKDIR}/${OUTDIR}/cov_html/

  #Step-3. Save the result to the ${WORKDIR} folder
  #Tar all results to a file
  cd ${WORKDIR}
  tar -zcvf ${WORKDIR}/${OUTDIR}.tar.gz ${OUTDIR}

  exit $STATUS
fi
