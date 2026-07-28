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
LABEL="voltron on ${DOCIMAGE}"
PROFUZZBENCH_RUN_START_EPOCH=$(date +%s)
mkdir -p "$SAVETO"

collect_results() {
  local index=1
  local id

  printf "\nVOLTRON: Collecting results and saving them to %s" "$SAVETO"
  for id in "${cids[@]}"; do
    printf "\nVOLTRON: Collecting results from container %s" "$id"
    if ! docker cp \
      "${id}:/home/ubuntu/voltron-runtime/${OUTDIR}.tar.gz" \
      "${SAVETO}/${OUTDIR}_${index}.tar.gz" > /dev/null 2>&1; then
      printf "\nVOLTRON: No archive available from container %s" "$id"
    fi
    if [ -n "$DELETE" ]; then
      docker rm "$id" > /dev/null 2>&1 || true
    fi
    index=$((index + 1))
  done
}

handle_interrupt() {
  trap - INT TERM
  printf "\nVOLTRON: Interrupt received. Cleaning up...\n"
  profuzzbench_stop_monitor "$MONITOR_PID"
  profuzzbench_interrupt_containers "${cids[@]}"
  profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"
  if [ "$PROFUZZBENCH_COLLECT_ON_INTERRUPT" = "1" ]; then
    collect_results
  fi
  printf "\nVOLTRON: Interrupted. Exiting with status 130.\n"
  exit 130
}

trap handle_interrupt INT TERM

VOLTRON_SOURCE=$("$ROOT/scripts/prepare_voltron.sh")
UV_CACHE=${VOLTRON_UV_CACHE_DIR:-"$ROOT/.runtime/voltron/uv-cache"}
mkdir -p "$UV_CACHE"
chmod 0777 "$UV_CACHE"

VOLTRON_LLM_CONFIG=${VOLTRON_LLM_CONFIG:-"$ROOT/config/voltron-llm.yaml"}
VOLTRON_KEY_POOL_COUNTER=${VOLTRON_LLM_API_KEY_COUNTER:-"$ROOT/.runtime/voltron/api-profile-counter"}
VOLTRON_KEY_POOL_LOCK="${VOLTRON_KEY_POOL_COUNTER}.lock"
VOLTRON_USE_API_GATEWAY=${VOLTRON_USE_API_GATEWAY:-0}
voltron_llm_profiles=()

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
  docker_args=(
    run --cpus=1 -d -it
    --mount "type=bind,src=${VOLTRON_SOURCE},dst=/opt/voltron-src,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_voltron_container.sh,dst=/opt/voltron-benchmark-runner.sh,readonly"
    --mount "type=bind,src=${UV_CACHE},dst=/home/ubuntu/.cache/uv"
    -e UV_CACHE_DIR=/home/ubuntu/.cache/uv
    -e UV_PYTHON_INSTALL_DIR=/home/ubuntu/.cache/uv/python
  )
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
if [ "$PROFUZZBENCH_MONITOR" != "0" ]; then
  profuzzbench_monitor_containers "$LABEL" "$TIMEOUT" "${cids[@]}" &
  MONITOR_PID=$!
fi
docker wait "${cids[@]}" > /dev/null
profuzzbench_stop_monitor "$MONITOR_PID"
profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"

collect_results

printf "\nVOLTRON: I am done!\n"
