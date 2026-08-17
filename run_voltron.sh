#!/bin/bash

set -u

DOCIMAGE=$1
RUNS=$2
SAVETO=$3
TARGET=$4
OUTDIR=$5
TIMEOUT=$6
SKIPCOUNT=${7:-5}
DELETE=${8:-}
VOLTRON_RUN_MODE=${VOLTRON_RUN_MODE:-full}
VOLTRON_MODEL_BATCH=${VOLTRON_MODEL_BATCH:-}
VOLTRON_LEARNING_BUNDLE_DIR=${VOLTRON_LEARNING_BUNDLE_DIR:-}
VOLTRON_NO_SPEC_KNOWLEDGE=${VOLTRON_NO_SPEC_KNOWLEDGE:-0}
VOLTRON_NO_STATE_LEARNING=${VOLTRON_NO_STATE_LEARNING:-0}
VOLTRON_NO_GUIDED_SCHEDULING=${VOLTRON_NO_GUIDED_SCHEDULING:-0}
VOLTRON_OFFLINE_MUTATOR_ONLY=${VOLTRON_OFFLINE_MUTATOR_ONLY:-0}
VOLTRON_NO_LOAD_AFLNET_SEEDS=${VOLTRON_NO_LOAD_AFLNET_SEEDS:-0}

for voltron_option in \
  VOLTRON_NO_SPEC_KNOWLEDGE \
  VOLTRON_NO_STATE_LEARNING \
  VOLTRON_NO_GUIDED_SCHEDULING \
  VOLTRON_OFFLINE_MUTATOR_ONLY \
  VOLTRON_NO_LOAD_AFLNET_SEEDS; do
  case "${!voltron_option}" in
    0|1) ;;
    *)
      printf '%s must be either 0 or 1.\n' "$voltron_option" >&2
      exit 2
      ;;
  esac
done

VOLTRON_NO_STATE_LEARNING_EFFECTIVE=$VOLTRON_NO_STATE_LEARNING
VOLTRON_NO_GUIDED_SCHEDULING_EFFECTIVE=$VOLTRON_NO_GUIDED_SCHEDULING
if [ "$VOLTRON_OFFLINE_MUTATOR_ONLY" = 1 ]; then
  VOLTRON_NO_STATE_LEARNING_EFFECTIVE=1
  VOLTRON_NO_GUIDED_SCHEDULING_EFFECTIVE=1
fi

case "$VOLTRON_RUN_MODE" in
  full|learn-export) ;;
  *)
    printf 'VOLTRON_RUN_MODE must be either full or learn-export.\n' >&2
    exit 2
    ;;
esac

if [ -n "$VOLTRON_MODEL_BATCH" ]; then
  if [ "$VOLTRON_RUN_MODE" != full ]; then
    printf 'VOLTRON_MODEL_BATCH requires VOLTRON_RUN_MODE=full.\n' >&2
    exit 2
  fi
  case "$VOLTRON_MODEL_BATCH" in
    *[!A-Za-z0-9._-]*|'')
      printf 'VOLTRON_MODEL_BATCH must be a safe batch name.\n' >&2
      exit 2
      ;;
  esac
  if [ -z "$VOLTRON_LEARNING_BUNDLE_DIR" ]; then
    printf 'VOLTRON_MODEL_BATCH requires VOLTRON_LEARNING_BUNDLE_DIR.\n' >&2
    exit 2
  fi
  VOLTRON_LEARNING_BUNDLE_PATH="$VOLTRON_LEARNING_BUNDLE_DIR/$TARGET/learning_bundle.tar.gz"
  if [ ! -r "$VOLTRON_LEARNING_BUNDLE_PATH" ]; then
    printf 'VOLTRON: missing learning bundle for %s: %s\n' \
      "$TARGET" "$VOLTRON_LEARNING_BUNDLE_PATH" >&2
    exit 2
  fi
fi

ROOT=$(cd "$(dirname "$0")" && pwd)
source "$ROOT/benchmark/scripts/execution/profuzzbench_monitor_common.sh"

MANIFEST_PATH="${PROFUZZBENCH_CONTAINER_MANIFEST:-${RESULTS_ROOT:-$SAVETO/..}/container-manifest.jsonl}"
MANIFEST_RUN_ID="${PROFUZZBENCH_RUN_ID:-unknown}"
DOCKER_DIAGNOSTICS_DIR="${PROFUZZBENCH_DOCKER_DIAGNOSTICS_DIR:-$SAVETO/docker}"
DOCKER_DIAGNOSTICS_FILE="$DOCKER_DIAGNOSTICS_DIR/diagnostics.jsonl"
DOCKER_EVENTS_PID=""
mkdir -p "$DOCKER_DIAGNOSTICS_DIR/inspect" "$DOCKER_DIAGNOSTICS_DIR/logs" \
  "$DOCKER_DIAGNOSTICS_DIR/events"

write_docker_diagnostic() {
  python3 "$ROOT/scripts/write_docker_diagnostic.py" \
    --output "$DOCKER_DIAGNOSTICS_FILE" \
    --kind "$1" --target "$TARGET" --replication "$2" \
    "${@:3}" >/dev/null 2>&1 || true
}

stop_docker_event_collector() {
  if [ -n "$DOCKER_EVENTS_PID" ]; then
    kill "$DOCKER_EVENTS_PID" 2>/dev/null || true
    wait "$DOCKER_EVENTS_PID" 2>/dev/null || true
    DOCKER_EVENTS_PID=""
  fi
}

start_docker_event_collector() {
  local event_file="$DOCKER_DIAGNOSTICS_DIR/events/${TARGET}.jsonl"
  local event_error="$DOCKER_DIAGNOSTICS_DIR/events/${TARGET}.stderr.log"

  if [ -z "${PROFUZZBENCH_RUN_ID:-}" ]; then
    return 0
  fi
  docker events --format '{{json .}}' \
    --filter "label=voltronbench.run_id=${PROFUZZBENCH_RUN_ID}" \
    >"$event_file" 2>"$event_error" &
  DOCKER_EVENTS_PID=$!
  write_docker_diagnostic events_started 0 \
    --status "$event_file"
}

capture_container_diagnostics() {
  local id=$1
  local index=$2
  local inspect_file="$DOCKER_DIAGNOSTICS_DIR/inspect/${TARGET}-${index}.json"
  local log_file="$DOCKER_DIAGNOSTICS_DIR/logs/${TARGET}-${index}.log"

  # The helper removes Config.Env and other credential-bearing fields before
  # writing inspect output. Container logs are intentionally kept separate.
  if docker inspect "$id" 2>"$inspect_file.stderr" \
    | python3 "$ROOT/scripts/sanitize_docker_inspect.py" >"$inspect_file"; then
    rm -f "$inspect_file.stderr"
  fi
  raw_log="${log_file}.raw"
  docker logs --timestamps "$id" >"$raw_log" 2>&1 || true
  max_log_bytes=${PROFUZZBENCH_DOCKER_LOG_MAX_BYTES:-10485760}
  case "$max_log_bytes" in
    ''|*[!0-9]*) max_log_bytes=10485760 ;;
  esac
  if [ "$(wc -c <"$raw_log")" -gt "$max_log_bytes" ]; then
    half=$((max_log_bytes / 2))
    head -c "$half" "$raw_log" >"$log_file"
    printf '\n[... docker log truncated ...]\n' >>"$log_file"
    tail -c "$half" "$raw_log" >>"$log_file"
    rm -f "$raw_log"
  else
    mv "$raw_log" "$log_file"
  fi
  write_docker_diagnostic container_diagnostics "$index" \
    --container-id "$id" --status "$inspect_file"
}

record_manifest() {
  python3 "$ROOT/scripts/record_container_manifest.py" "$@" \
    >/dev/null 2>&1 || true
}

cids=()
MONITOR_PID=""
MONITOR_PROGRESS_FILE=""
WAIT_PID=""
WAIT_STATUS_FILE=""
LABEL="voltron on ${DOCIMAGE}"
PROFUZZBENCH_RUN_START_EPOCH=${PROFUZZBENCH_RUN_START_EPOCH:-$(date +%s)}
PROFUZZBENCH_EXTERNAL_MONITOR=${PROFUZZBENCH_EXTERNAL_MONITOR:-0}
mkdir -p "$SAVETO"

copy_container_result() {
  local id=$1
  local destination=$2
  local partial_root

  if docker cp \
    "${id}:/home/ubuntu/voltron-runtime/${OUTDIR}.tar.gz" \
    "$destination" > /dev/null 2>&1; then
    return 0
  fi

  partial_root=$(mktemp -d "$SAVETO/.voltron-partial.XXXXXX") || return 1
  if docker cp \
      "${id}:/home/ubuntu/voltron-runtime/${OUTDIR}" \
      "$partial_root/" > /dev/null 2>&1 \
    && tar -zcf "$destination" -C "$partial_root" "$OUTDIR"; then
    printf "\nVOLTRON: Saved partial result directory from container %s" "$id"
    rm -rf -- "$partial_root"
    return 0
  fi

  rm -rf -- "$partial_root"
  return 1
}

collect_results() {
  local index=1
  local id
  local copied=0
  local status=0

  printf "\nVOLTRON: Collecting results and saving them to %s" "$SAVETO"
  for id in "${cids[@]}"; do
    write_monitor_progress "Collecting archives $((index - 1))/${#cids[@]}"
    printf "\nVOLTRON: Collecting results from container %s" "$id"
    if ! copy_container_result \
      "$id" "${SAVETO}/${OUTDIR}_${index}.tar.gz"; then
      printf "\nVOLTRON: No result directory available from container %s" "$id"
      status=1
    else
      copied=$((copied + 1))
      record_manifest \
        --manifest "$MANIFEST_PATH" --event archived \
        --run-id "$MANIFEST_RUN_ID" --target "$TARGET" \
        --fuzzer voltron --replication "$index" --container-id "$id" \
        --result-dir "$SAVETO" \
        --archive-path "${SAVETO}/${OUTDIR}_${index}.tar.gz" \
        --timeout-seconds "$TIMEOUT"
    fi
    if [ -n "$DELETE" ]; then
      docker rm "$id" > /dev/null 2>&1 || true
    fi
    index=$((index + 1))
  done
  write_monitor_progress "Archive collection complete: ${copied}/${#cids[@]}"
  return "$status"
}

write_monitor_progress() {
  if [ -n "$MONITOR_PROGRESS_FILE" ]; then
    printf '%s\n' "$1" > "$MONITOR_PROGRESS_FILE"
  fi
}

remove_monitor_progress_file() {
  if [ -n "$MONITOR_PROGRESS_FILE" ]; then
    rm -f -- "$MONITOR_PROGRESS_FILE"
    MONITOR_PROGRESS_FILE=""
  fi
}

stop_container_waiter() {
  if [ -n "$WAIT_PID" ]; then
    kill "$WAIT_PID" 2>/dev/null || true
    wait "$WAIT_PID" 2>/dev/null || true
    WAIT_PID=""
  fi
}

remove_wait_status_file() {
  if [ -n "$WAIT_STATUS_FILE" ]; then
    rm -f -- "$WAIT_STATUS_FILE"
    WAIT_STATUS_FILE=""
  fi
}

handle_interrupt() {
  trap - INT TERM
  printf "\nVOLTRON: Interrupt received. Cleaning up...\n"
  write_monitor_progress "Interrupted; stopping containers"
  stop_container_waiter
  stop_docker_event_collector
  profuzzbench_stop_monitor "$MONITOR_PID"
  profuzzbench_interrupt_containers "${cids[@]}"
  if [ "$PROFUZZBENCH_EXTERNAL_MONITOR" != "1" ]; then
    profuzzbench_print_final_container_summary \
      "$LABEL" "$TIMEOUT" "${cids[@]}"
  fi
  if [ "$PROFUZZBENCH_COLLECT_ON_INTERRUPT" = "1" ]; then
    collect_results || true
  fi
  remove_wait_status_file
  remove_monitor_progress_file
  printf "\nVOLTRON: Interrupted. Exiting with status 130.\n"
  exit 130
}

trap handle_interrupt INT TERM

VOLTRON_SOURCE=$("$ROOT/scripts/prepare_voltron.sh")
if [[ "$VOLTRON_RUN_MODE" == "learn-export" ]] \
  && ! grep -Fq -- '--learn-and-export' "$VOLTRON_SOURCE/cli.py"; then
  printf 'VOLTRON: INCOMPATIBLE_VOLTRON_SNAPSHOT; --learn-and-export is missing\n' >&2
  exit 2
fi
if [[ -n "$VOLTRON_MODEL_BATCH" ]] \
  && { ! grep -Fq -- '--import-learning-bundle' "$VOLTRON_SOURCE/cli.py" \
    || ! grep -Fq -- '--model-batch' "$VOLTRON_SOURCE/cli.py"; }; then
  printf 'VOLTRON: INCOMPATIBLE_VOLTRON_SNAPSHOT; model batch support is missing\n' >&2
  exit 2
fi
UV_CACHE_ROOT=${VOLTRON_UV_CACHE_ROOT:-"$ROOT/.runtime/voltron/uv-cache"}
UV_CACHE_TEMPLATE=${VOLTRON_UV_CACHE_TEMPLATE:-"$ROOT/.runtime/voltron/uv-cache-template"}
UV_CACHE_MODE=${VOLTRON_UV_CACHE_MODE:-prewarmed-private}
UV_CACHE_PERMISSION_HELPER="$ROOT/scripts/normalize_voltron_uv_cache_permissions.sh"

prepare_uv_cache_instance() {
  local cache_dir=$1
  local temporary

  if [ -f "$cache_dir/.ready" ]; then
    "$UV_CACHE_PERMISSION_HELPER" "$cache_dir"
    return $?
  fi
  mkdir -p "$(dirname "$cache_dir")"
  temporary=$(mktemp -d "${cache_dir}.tmp.XXXXXX")
  if ! cp -a --reflink=auto "$UV_CACHE_TEMPLATE/." "$temporary/"; then
    mv "$temporary" "${cache_dir}.failed.$(date +%s).$$" 2>/dev/null || true
    return 1
  fi
  if ! "$UV_CACHE_PERMISSION_HELPER" "$temporary"; then
    mv "$temporary" "${cache_dir}.failed.$(date +%s).$$" 2>/dev/null || true
    return 1
  fi
  if [ -e "$cache_dir" ]; then
    mv "$cache_dir" "${cache_dir}.incomplete.$(date +%s).$$"
  fi
  mv "$temporary" "$cache_dir"
}

if [ "$UV_CACHE_MODE" != legacy ]; then
  "$ROOT/scripts/prepare_voltron_uv_cache.sh" "$DOCIMAGE" "$VOLTRON_SOURCE"
fi

VOLTRON_LLM_CONFIG=${VOLTRON_LLM_CONFIG:-"$ROOT/config/voltron-llm.yaml"}
VOLTRON_KEY_POOL_COUNTER=${VOLTRON_LLM_API_KEY_COUNTER:-"$ROOT/.runtime/voltron/api-profile-counter"}
VOLTRON_KEY_POOL_LOCK="${VOLTRON_KEY_POOL_COUNTER}.lock"
VOLTRON_USE_API_GATEWAY=${VOLTRON_USE_API_GATEWAY:-0}
voltron_llm_profiles=()

case "$TARGET" in
  live555)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/RTSP/Live555/cov_script.sh"
    ;;
  kamailio)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/SIP/Kamailio/cov_script.sh"
    ;;
  exim)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/SMTP/Exim/cov_script.sh"
    ;;
  forked-daapd)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/DAAP/forked-daapd/cov_script.sh"
    ;;
  pure-ftpd)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/FTP/PureFTPD/cov_script.sh"
    ;;
  proftpd)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/FTP/ProFTPD/cov_script.sh"
    ;;
  bftpd)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/FTP/BFTPD/cov_script.sh"
    ;;
  lightftp)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/FTP/LightFTP/cov_script.sh"
    ;;
  lighttpd1)
    TARGET_COVERAGE_SCRIPT="$ROOT/benchmark/subjects/HTTP/Lighttpd1/cov_script.sh"
    ;;
  *)
    printf 'VOLTRON: no coverage script for target %s\n' "$TARGET" >&2
    exit 2
    ;;
esac

load_llm_profiles() {
  local profile_data

  if [ ! -r "$VOLTRON_LLM_CONFIG" ]; then
    printf 'VOLTRON: LLM configuration is not readable: %s\n' "$VOLTRON_LLM_CONFIG" >&2
    printf 'VOLTRON: copy config/voltron-llm.example.yaml to config/voltron-llm.yaml\n' >&2
    exit 1
  fi
  if ! profile_data=$(python3 "$ROOT/scripts/load_voltron_llm_config.py" "$VOLTRON_LLM_CONFIG"); then
    exit 1
  fi
  mapfile -t voltron_llm_profiles <<< "$profile_data"
  if (( ${#voltron_llm_profiles[@]} == 0 || ${#voltron_llm_profiles[@]} % 3 != 0 )); then
    printf 'VOLTRON: invalid profile data from %s\n' "$VOLTRON_LLM_CONFIG" >&2
    exit 1
  fi
}

select_llm_profile() {
  local pool_size=$(( ${#voltron_llm_profiles[@]} / 3 ))
  local counter next index

  [ "$pool_size" -gt 0 ] || return 1

  mkdir -p "$(dirname "$VOLTRON_KEY_POOL_COUNTER")"
  {
    flock 8
    if [ -f "$VOLTRON_KEY_POOL_COUNTER" ]; then
      counter=$(<"$VOLTRON_KEY_POOL_COUNTER")
    else
      counter=0
    fi
    case "$counter" in
      ''|*[!0-9]*) counter=0 ;;
    esac
    index=$((counter % pool_size))
    next=$((counter + 1))
    printf '%s\n' "$next" > "$VOLTRON_KEY_POOL_COUNTER"
    printf '%s\n' "$index"
  } 8>"$VOLTRON_KEY_POOL_LOCK"
}

if [ "$VOLTRON_USE_API_GATEWAY" != "1" ]; then
  load_llm_profiles
fi

start_docker_event_collector

for i in $(seq 1 "$RUNS"); do
  # uv mutates its cache while installing dependencies.  A shared bind mount
  # is unsafe for parallel targets: one container can leave root-owned cache
  # entries that make another container's ubuntu user fail with EACCES.  Keep
  # the default cache isolated per target/instance; callers can still opt into
  # a specific cache with VOLTRON_UV_CACHE_DIR for single-container runs.
  if [ -n "${VOLTRON_UV_CACHE_DIR:-}" ]; then
    UV_CACHE="$VOLTRON_UV_CACHE_DIR"
  elif [ "$UV_CACHE_MODE" != legacy ]; then
    UV_CACHE="$UV_CACHE_ROOT/runs/${MANIFEST_RUN_ID}/${TARGET}-${i}"
  else
    UV_CACHE="$UV_CACHE_ROOT/${TARGET}-${i}"
  fi
  if [ "$UV_CACHE_MODE" != legacy ] \
    && ! prepare_uv_cache_instance "$UV_CACHE"; then
    printf 'VOLTRON: failed to prepare private uv cache: %s\n' \
      "$UV_CACHE" >&2
    stop_docker_event_collector
    exit 2
  fi
  mkdir -p "$UV_CACHE"
  if ! "$UV_CACHE_PERMISSION_HELPER" "$UV_CACHE"; then
    printf 'VOLTRON: failed to normalize uv cache permissions: %s\n' \
      "$UV_CACHE" >&2
    stop_docker_event_collector
    exit 2
  fi
  docker_args=(
    run --init --cpus=1 -d -it
    --mount "type=bind,src=${VOLTRON_SOURCE},dst=/opt/voltron-src,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_voltron_container.sh,dst=/opt/voltron-benchmark-runner.sh,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-subject-overrides,dst=/opt/voltron-subject-overrides,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-main-runtime.patch,dst=/opt/voltron-main-runtime.patch,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-udp-bind-runtime.patch,dst=/opt/voltron-udp-bind-runtime.patch,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-executor-readiness-runtime.patch,dst=/opt/voltron-executor-readiness-runtime.patch,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-generator-evolution-runtime.patch,dst=/opt/voltron-generator-evolution-runtime.patch,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_export_voltron_replay.py,dst=/opt/voltron-export-aflnet-replay.py,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_voltron_coverage.sh,dst=/opt/voltron-coverage.sh,readonly"
    --mount "type=bind,src=${TARGET_COVERAGE_SCRIPT},dst=/opt/voltron-target-cov-script.sh,readonly"
    --mount "type=bind,src=${UV_CACHE},dst=/home/ubuntu/.cache/uv"
    -e UV_CACHE_DIR=/home/ubuntu/.cache/uv
    -e UV_PYTHON_INSTALL_DIR=/home/ubuntu/.cache/uv/python
  )
  if [ -n "$VOLTRON_MODEL_BATCH" ]; then
    docker_args+=(
      --mount "type=bind,src=${VOLTRON_LEARNING_BUNDLE_PATH},dst=/opt/voltron-learning-bundle.tar.gz,readonly"
      -e "VOLTRON_MODEL_BATCH=${VOLTRON_MODEL_BATCH}"
      -e VOLTRON_LEARNING_BUNDLE_PATH=/opt/voltron-learning-bundle.tar.gz
    )
  fi
  if [ "$UV_CACHE_MODE" != legacy ]; then
    docker_args+=(-e UV_OFFLINE=1)
  fi
  if [ "$TARGET" = "kamailio" ]; then
    docker_args+=(--env KAMAILIO_CONTAINER_INIT=enabled)
  fi
  if [ -n "${PROFUZZBENCH_RUN_ID:-}" ]; then
    docker_args+=(
      --label "voltronbench.run_id=${PROFUZZBENCH_RUN_ID}"
      --label "voltronbench.project=${TARGET}"
      --label "voltronbench.mode=${VOLTRON_RUN_MODE}"
      --label "voltronbench.no_spec_knowledge=${VOLTRON_NO_SPEC_KNOWLEDGE}"
      --label "voltronbench.no_state_learning=${VOLTRON_NO_STATE_LEARNING_EFFECTIVE}"
      --label "voltronbench.no_guided_scheduling=${VOLTRON_NO_GUIDED_SCHEDULING_EFFECTIVE}"
      --label "voltronbench.offline_mutator_only=${VOLTRON_OFFLINE_MUTATOR_ONLY}"
      --label "voltronbench.no_load_aflnet_seeds=${VOLTRON_NO_LOAD_AFLNET_SEEDS}"
      --label "voltronbench.project_index=${PROFUZZBENCH_PROJECT_INDEX:-0}"
      --label "voltronbench.stage_file=/home/ubuntu/voltron-runtime/${OUTDIR}/.profuzzbench-stage"
    )
  fi
  if [ "$VOLTRON_USE_API_GATEWAY" = "1" ]; then
    docker_args+=(
      --network "${VOLTRON_DOCKER_NETWORK:-voltronbench}"
      -e "VOLTRON_LLM_BASE_URL=${VOLTRON_GATEWAY_BASE_URL:-http://voltron-api-gateway:8000/v1}"
      -e "VOLTRON_LLM_API_KEY=${VOLTRON_GATEWAY_TOKEN:-voltronbench-internal}"
      -e "VOLTRON_LLM_MODEL=${VOLTRON_GATEWAY_MODEL:-voltron-default}"
    )
  fi
  for env_name in \
    VOLTRON_RUN_MODE \
    VOLTRON_MODEL_BATCH \
    VOLTRON_NO_SPEC_KNOWLEDGE \
    VOLTRON_NO_STATE_LEARNING \
    VOLTRON_NO_GUIDED_SCHEDULING \
    VOLTRON_OFFLINE_MUTATOR_ONLY \
    VOLTRON_NO_LOAD_AFLNET_SEEDS \
    VOLTRON_STATS_INTERVAL \
    VOLTRON_COMPLIANCE_ANALYZER \
    VOLTRON_RUN_COMPLIANCE_ANALYSIS \
    VOLTRON_FORKED_DAAPD_SETUP_TIMEOUT_SECONDS \
    VOLTRON_FORKED_DAAPD_READINESS_TIMEOUT_SECONDS; do
    if [ -n "${!env_name:-}" ]; then
      docker_args+=(-e "${env_name}=${!env_name}")
    fi
  done
  if [ "$VOLTRON_USE_API_GATEWAY" != "1" ] \
    && [ "${#voltron_llm_profiles[@]}" -gt 0 ]; then
    profile_index=$(select_llm_profile)
    profile_offset=$((profile_index * 3))
    docker_args+=(
      -e "VOLTRON_LLM_BASE_URL=$(printf '%s' "${voltron_llm_profiles[$profile_offset]}" | base64 -d)"
      -e "VOLTRON_LLM_API_KEY=$(printf '%s' "${voltron_llm_profiles[$((profile_offset + 1))]}" | base64 -d)"
      -e "VOLTRON_LLM_MODEL=$(printf '%s' "${voltron_llm_profiles[$((profile_offset + 2))]}" | base64 -d)"
    )
  fi

  stderr_file="$DOCKER_DIAGNOSTICS_DIR/${TARGET}-${i}.docker-run.stderr.log"
  printf -v command_summary '%q ' docker "${docker_args[@]}" "$DOCIMAGE" /bin/bash \
    /opt/voltron-benchmark-runner.sh "$TARGET" "$OUTDIR" "$TIMEOUT" "$SKIPCOUNT"
  id=$(docker "${docker_args[@]}" "$DOCIMAGE" /bin/bash \
    /opt/voltron-benchmark-runner.sh "$TARGET" "$OUTDIR" "$TIMEOUT" "$SKIPCOUNT" \
    2>"$stderr_file")
  docker_rc=$?
  write_docker_diagnostic create_finished "$i" \
    --returncode "$docker_rc" --container-id "$id" \
    --stderr "$stderr_file" --command "$command_summary"
  if [ "$docker_rc" -ne 0 ] || [ -z "$id" ]; then
    printf '\nVOLTRON: docker run failed for %s replication %s (rc=%s); stderr: %s\n' \
      "$TARGET" "$i" "$docker_rc" "$stderr_file" >&2
    cat "$stderr_file" >&2
    stop_docker_event_collector
    exit 125
  fi
  cids+=("${id::12}")
  record_manifest \
    --manifest "$MANIFEST_PATH" --event started \
    --run-id "$MANIFEST_RUN_ID" --target "$TARGET" \
    --fuzzer voltron --replication "$i" --container-id "${id::12}" \
    --result-dir "$SAVETO" --timeout-seconds "$TIMEOUT"
done

printf "\nVOLTRON: Fuzzing in progress ..."
printf "\nVOLTRON: Waiting for the following containers to stop: %s" "${cids[*]}"
if [ "$PROFUZZBENCH_MONITOR" != "0" ] \
  && [ "$PROFUZZBENCH_EXTERNAL_MONITOR" != "1" ]; then
  MONITOR_PROGRESS_FILE=$(mktemp "$SAVETO/.voltron-monitor-progress.XXXXXX")
  PROFUZZBENCH_MONITOR_STAGE_FILE="/home/ubuntu/voltron-runtime/${OUTDIR}/.profuzzbench-stage"
  PROFUZZBENCH_MONITOR_PROGRESS_FILE="$MONITOR_PROGRESS_FILE"
  write_monitor_progress "Fuzzing containers"
  profuzzbench_monitor_containers "$LABEL" "$TIMEOUT" "${cids[@]}" &
  MONITOR_PID=$!
fi
CONTAINER_STATUS=0
WAIT_STATUS_FILE=$(mktemp "$SAVETO/.voltron-wait-status.XXXXXX")
docker wait "${cids[@]}" > "$WAIT_STATUS_FILE" &
WAIT_PID=$!
if ! wait "$WAIT_PID"; then
  printf "\nVOLTRON: Failed while waiting for containers"
  CONTAINER_STATUS=1
fi
WAIT_PID=""

index=0
while IFS= read -r exit_code; do
  if [ "$index" -ge "${#cids[@]}" ]; then
    break
  fi
  if [ "$exit_code" != "0" ]; then
    printf "\nVOLTRON: Container %s exited with status %s" \
      "${cids[$index]}" "$exit_code"
    CONTAINER_STATUS=1
  fi
  record_manifest \
    --manifest "$MANIFEST_PATH" --event finished \
    --run-id "$MANIFEST_RUN_ID" --target "$TARGET" \
    --fuzzer voltron --replication "$((index + 1))" \
    --container-id "${cids[$index]}" --result-dir "$SAVETO" \
    --exit-code "$exit_code" --timeout-seconds "$TIMEOUT"
  index=$((index + 1))
done < "$WAIT_STATUS_FILE"
if [ "$index" -ne "${#cids[@]}" ]; then
  printf "\nVOLTRON: Missing exit status for one or more containers"
  CONTAINER_STATUS=1
fi
remove_wait_status_file

write_monitor_progress "Fuzzing finished; preparing archive collection"
for index in "${!cids[@]}"; do
  capture_container_diagnostics "${cids[$index]}" "$((index + 1))"
done
if ! collect_results; then
  CONTAINER_STATUS=1
fi
stop_docker_event_collector
profuzzbench_stop_monitor "$MONITOR_PID"
if [ "$PROFUZZBENCH_EXTERNAL_MONITOR" != "1" ]; then
  profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"
fi
remove_monitor_progress_file

if [ "$CONTAINER_STATUS" -ne 0 ]; then
  printf "\nVOLTRON: Completed with failed container(s).\n"
  exit "$CONTAINER_STATUS"
fi

printf "\nVOLTRON: I am done!\n"
