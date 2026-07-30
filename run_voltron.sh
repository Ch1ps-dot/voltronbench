#!/bin/bash

set -u

DOCIMAGE=$1
RUNS=$2
SAVETO=$3
TARGET=$4
OUTDIR=$5
TIMEOUT=$6
SKIPCOUNT=${7:-1}
DELETE=${8:-}

ROOT=$(cd "$(dirname "$0")" && pwd)
source "$ROOT/benchmark/scripts/execution/profuzzbench_monitor_common.sh"

cids=()
MONITOR_PID=""
MONITOR_PROGRESS_FILE=""
LABEL="voltron on ${DOCIMAGE}"
PROFUZZBENCH_RUN_START_EPOCH=${PROFUZZBENCH_RUN_START_EPOCH:-$(date +%s)}
PROFUZZBENCH_EXTERNAL_MONITOR=${PROFUZZBENCH_EXTERNAL_MONITOR:-0}
mkdir -p "$SAVETO"

collect_results() {
  local index=1
  local id
  local copied=0

  printf "\nVOLTRON: Collecting results and saving them to %s" "$SAVETO"
  for id in "${cids[@]}"; do
    write_monitor_progress "Collecting archives $((index - 1))/${#cids[@]}"
    printf "\nVOLTRON: Collecting results from container %s" "$id"
    if ! docker cp \
      "${id}:/home/ubuntu/voltron-runtime/${OUTDIR}.tar.gz" \
      "${SAVETO}/${OUTDIR}_${index}.tar.gz" > /dev/null 2>&1; then
      printf "\nVOLTRON: No archive available from container %s" "$id"
    else
      copied=$((copied + 1))
    fi
    if [ -n "$DELETE" ]; then
      docker rm "$id" > /dev/null 2>&1 || true
    fi
    index=$((index + 1))
  done
  write_monitor_progress "Archive collection complete: ${copied}/${#cids[@]}"
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

handle_interrupt() {
  trap - INT TERM
  printf "\nVOLTRON: Interrupt received. Cleaning up...\n"
  write_monitor_progress "Interrupted; stopping containers"
  profuzzbench_stop_monitor "$MONITOR_PID"
  profuzzbench_interrupt_containers "${cids[@]}"
  if [ "$PROFUZZBENCH_EXTERNAL_MONITOR" != "1" ]; then
    profuzzbench_print_final_container_summary \
      "$LABEL" "$TIMEOUT" "${cids[@]}"
  fi
  if [ "$PROFUZZBENCH_COLLECT_ON_INTERRUPT" = "1" ]; then
    collect_results
  fi
  remove_monitor_progress_file
  printf "\nVOLTRON: Interrupted. Exiting with status 130.\n"
  exit 130
}

trap handle_interrupt INT TERM

VOLTRON_SOURCE=$("$ROOT/scripts/prepare_voltron.sh")
UV_CACHE_ROOT=${VOLTRON_UV_CACHE_ROOT:-"$ROOT/.runtime/voltron/uv-cache"}

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

for i in $(seq 1 "$RUNS"); do
  # uv mutates its cache while installing dependencies.  A shared bind mount
  # is unsafe for parallel targets: one container can leave root-owned cache
  # entries that make another container's ubuntu user fail with EACCES.  Keep
  # the default cache isolated per target/instance; callers can still opt into
  # a specific cache with VOLTRON_UV_CACHE_DIR for single-container runs.
  if [ -n "${VOLTRON_UV_CACHE_DIR:-}" ]; then
    UV_CACHE="$VOLTRON_UV_CACHE_DIR"
  else
    UV_CACHE="$UV_CACHE_ROOT/${TARGET}-${i}"
  fi
  mkdir -p "$UV_CACHE"
  chmod 0777 "$UV_CACHE"
  docker_args=(
    run --cpus=1 -d -it
    --mount "type=bind,src=${VOLTRON_SOURCE},dst=/opt/voltron-src,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_voltron_container.sh,dst=/opt/voltron-benchmark-runner.sh,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-subject-overrides,dst=/opt/voltron-subject-overrides,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/voltron-main-runtime.patch,dst=/opt/voltron-main-runtime.patch,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_export_voltron_replay.py,dst=/opt/voltron-export-aflnet-replay.py,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_voltron_coverage.sh,dst=/opt/voltron-coverage.sh,readonly"
    --mount "type=bind,src=${TARGET_COVERAGE_SCRIPT},dst=/opt/voltron-target-cov-script.sh,readonly"
    --mount "type=bind,src=${UV_CACHE},dst=/home/ubuntu/.cache/uv"
    -e UV_CACHE_DIR=/home/ubuntu/.cache/uv
    -e UV_PYTHON_INSTALL_DIR=/home/ubuntu/.cache/uv/python
  )
  if [ -n "${PROFUZZBENCH_RUN_ID:-}" ]; then
    docker_args+=(
      --label "voltronbench.run_id=${PROFUZZBENCH_RUN_ID}"
      --label "voltronbench.project=${TARGET}"
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
  for env_name in VOLTRON_STATS_INTERVAL VOLTRON_COMPLIANCE_ANALYZER; do
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

  id=$(docker "${docker_args[@]}" "$DOCIMAGE" /bin/bash \
    /opt/voltron-benchmark-runner.sh "$TARGET" "$OUTDIR" "$TIMEOUT" "$SKIPCOUNT")
  cids+=("${id::12}")
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
docker wait "${cids[@]}" > /dev/null
write_monitor_progress "Fuzzing finished; preparing archive collection"
collect_results
profuzzbench_stop_monitor "$MONITOR_PID"
if [ "$PROFUZZBENCH_EXTERNAL_MONITOR" != "1" ]; then
  profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"
fi
remove_monitor_progress_file

printf "\nVOLTRON: I am done!\n"
