#!/bin/bash

DOCIMAGE=$1   #name of the docker image
RUNS=$2       #number of runs
SAVETO=$3     #path to folder keeping the results

FUZZER=$4     #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
OUTDIR=$5     #name of the output folder created inside the docker container
OPTIONS=$6    #all configured options for fuzzing
TIMEOUT=$7    #time for fuzzing
SKIPCOUNT=$8  #used for calculating coverage over time. e.g., SKIPCOUNT=5 means we run gcovr after every 5 test cases
DELETE=${9:-}

WORKDIR="/home/ubuntu/experiments"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
source "$SCRIPT_DIR/profuzzbench_monitor_common.sh"

#keep all container ids
cids=()
MONITOR_PID=""
LABEL="${FUZZER} on ${DOCIMAGE}"
PROFUZZBENCH_RUN_START_EPOCH=$(date +%s)

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

if [[ "$FUZZER" == "chatafl" ]]; then
  CHATAFL_USE_API_GATEWAY=${CHATAFL_USE_API_GATEWAY:-0}
  if [[ "$CHATAFL_USE_API_GATEWAY" != "0" \
    && "$CHATAFL_USE_API_GATEWAY" != "1" ]]; then
    printf 'CHATAFL_USE_API_GATEWAY must be either 0 or 1.\n' >&2
    exit 1
  fi
  CHATAFL_API_MODE="${CHATAFL_API_MODE:-direct}"
  if [[ "$CHATAFL_USE_API_GATEWAY" == "1" ]]; then
    CHATAFL_API_MODE=gateway
    CHATAFL_DOCKER_NETWORK="${CHATAFL_DOCKER_NETWORK:-voltronbench}"
  fi

  if [[ -z "${CHATAFL_RUNTIME_BINARY:-}" ]]; then
    CHATAFL_RUNTIME_BINARY=$(
      "$PROJECT_ROOT/scripts/prepare_chatafl_runtime.sh" \
        "${CHATAFL_BUILDER_IMAGE:-$DOCIMAGE}"
    )
  fi
  if [[ ! -x "$CHATAFL_RUNTIME_BINARY" ]]; then
    printf 'ChatAFL runtime binary is not executable: %s\n' \
      "$CHATAFL_RUNTIME_BINARY" >&2
    exit 1
  fi

  CHATAFL_RUNTIME_METADATA="${CHATAFL_RUNTIME_BINARY%/*}/metadata.txt"
  CHATAFL_COMPILED_DEFAULT_MODEL=
  CHATAFL_COMPILED_DEFAULT_URL=
  if [[ -f "$CHATAFL_RUNTIME_METADATA" ]]; then
    CHATAFL_COMPILED_DEFAULT_MODEL=$(
      metadata_value compiled_default_model "$CHATAFL_RUNTIME_METADATA"
    )
    CHATAFL_COMPILED_DEFAULT_URL=$(
      metadata_value compiled_default_url "$CHATAFL_RUNTIME_METADATA"
    )
  fi
  CHATAFL_MODEL_EFFECTIVE="${CHATAFL_MODEL_EFFECTIVE:-${CHATAFL_MODEL:-$CHATAFL_COMPILED_DEFAULT_MODEL}}"
  CHATAFL_URL_EFFECTIVE="${CHATAFL_URL_EFFECTIVE:-${CHATAFL_URL:-$CHATAFL_COMPILED_DEFAULT_URL}}"
  if [[ -z "$CHATAFL_MODEL_EFFECTIVE" ]]; then
    printf 'Set CHATAFL_MODEL when using a custom ChatAFL runtime binary.\n' >&2
    exit 1
  fi
  if [[ -z "$CHATAFL_URL_EFFECTIVE" ]]; then
    printf 'Set CHATAFL_URL when using a custom ChatAFL runtime binary.\n' >&2
    exit 1
  fi
  if [[ "$CHATAFL_MODEL_EFFECTIVE" == *$'\n'* \
    || "$CHATAFL_MODEL_EFFECTIVE" == *$'\r'* ]]; then
    printf 'CHATAFL_MODEL must not contain a newline.\n' >&2
    exit 1
  fi
  if [[ "$CHATAFL_URL_EFFECTIVE" == *$'\n'* \
    || "$CHATAFL_URL_EFFECTIVE" == *$'\r'* ]]; then
    printf 'CHATAFL_URL must not contain a newline.\n' >&2
    exit 1
  fi
  if [[ -n "${CHATAFL_API_KEY:-}" \
    && -z "${CHATAFL_API_KEY_FILE:-}" ]]; then
    printf 'The common executor accepts API keys only through CHATAFL_API_KEY_FILE.\n' >&2
    printf 'Use run.sh to convert CHATAFL_API_KEY into a temporary secret file.\n' >&2
    exit 1
  fi

  CHATAFL_API_KEY_SOURCE=compiled_default
  if [[ -n "${CHATAFL_API_KEY_FILE:-}" ]]; then
    if [[ ! -f "$CHATAFL_API_KEY_FILE" \
      || ! -s "$CHATAFL_API_KEY_FILE" \
      || ! -r "$CHATAFL_API_KEY_FILE" ]]; then
      printf 'ChatAFL API key file is empty or not readable.\n' >&2
      exit 1
    fi
    CHATAFL_API_KEY_FILE=$(readlink -f "$CHATAFL_API_KEY_FILE")
    CHATAFL_API_KEY_MODE=$(stat -c '%a' "$CHATAFL_API_KEY_FILE")
    if (( (8#${CHATAFL_API_KEY_MODE} & 8#077) != 0 )); then
      printf 'ChatAFL API key file must not be accessible by group or others.\n' >&2
      exit 1
    fi
    if [[ "$CHATAFL_API_MODE" == "gateway" ]]; then
      CHATAFL_API_KEY_SOURCE=gateway_internal_token
    else
      CHATAFL_API_KEY_SOURCE=runtime_secret_file
    fi
  fi

  mkdir -p "$SAVETO"
  CHATAFL_RUNTIME_BINARY_SHA256=$(
    sha256sum "$CHATAFL_RUNTIME_BINARY" | cut -d ' ' -f 1
  )
  {
    printf 'api_mode=%s\n' "$CHATAFL_API_MODE"
    printf 'effective_model=%s\n' "$CHATAFL_MODEL_EFFECTIVE"
    printf 'effective_url=%s\n' "$CHATAFL_URL_EFFECTIVE"
    printf 'api_key_source=%s\n' "$CHATAFL_API_KEY_SOURCE"
    if [[ "$CHATAFL_API_MODE" == "gateway" ]]; then
      printf 'gateway_config_sha256=%s\n' \
        "${LLM_GATEWAY_CONFIG_SHA256:-unknown}"
      printf 'gateway_profile_models=%s\n' \
        "${LLM_GATEWAY_PROFILE_MODELS:-unknown}"
    fi
    printf 'runtime_binary_sha256=%s\n' \
      "$CHATAFL_RUNTIME_BINARY_SHA256"
    if [[ -f "$CHATAFL_RUNTIME_METADATA" ]]; then
      cat "$CHATAFL_RUNTIME_METADATA"
    fi
  } > "$SAVETO/chatafl_runtime_metadata.txt"
fi

collect_results() {
  local index=1
  local id
  local status=0

  printf "\n${FUZZER^^}: Collecting results and save them to ${SAVETO}"
  for id in "${cids[@]}"; do
    printf "\n${FUZZER^^}: Collecting results from container ${id}"
    if ! docker cp "${id}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "${SAVETO}/${OUTDIR}_${index}.tar.gz" > /dev/null 2>&1; then
      printf "\n${FUZZER^^}: No archive available from container ${id}"
      status=1
    fi
    if [ -n "$DELETE" ]; then
      printf "\nDeleting ${id}"
      docker rm "${id}" > /dev/null 2>&1 || true
    fi
    index=$((index+1))
  done
  return "$status"
}

handle_interrupt() {
  trap - INT TERM
  printf "\n${FUZZER^^}: Interrupt received. Cleaning up...\n"
  profuzzbench_stop_monitor "$MONITOR_PID"
  profuzzbench_interrupt_containers "${cids[@]}"
  profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"
  if [ "$PROFUZZBENCH_COLLECT_ON_INTERRUPT" = "1" ]; then
    collect_results
  fi
  printf "\n${FUZZER^^}: Interrupted. Exiting with status 130.\n"
  exit 130
}

trap handle_interrupt INT TERM

#create one container for each run
for i in $(seq 1 $RUNS); do
  docker_args=(run --cpus=1 -d -it)
  if [[ "$FUZZER" == "chatafl" ]]; then
    if [[ "$CHATAFL_USE_API_GATEWAY" == "1" ]]; then
      docker_args+=(--network "$CHATAFL_DOCKER_NETWORK")
    fi
    docker_args+=(
      --mount "type=bind,src=${CHATAFL_RUNTIME_BINARY},dst=/home/ubuntu/chatafl/afl-fuzz,readonly"
      --env "CHATAFL_MODEL=${CHATAFL_MODEL_EFFECTIVE}"
      --env "CHATAFL_URL=${CHATAFL_URL_EFFECTIVE}"
    )
    if [[ -n "${CHATAFL_API_KEY_FILE:-}" ]]; then
      docker_args+=(
        --mount "type=bind,src=${CHATAFL_API_KEY_FILE},dst=/run/secrets/chatafl_api_key,readonly"
        --env "CHATAFL_API_KEY_FILE=/run/secrets/chatafl_api_key"
      )
    fi
  fi
  id=$(docker "${docker_args[@]}" "$DOCIMAGE" /bin/bash -c \
    "cd ${WORKDIR} && run ${FUZZER} ${OUTDIR} '${OPTIONS}' ${TIMEOUT} ${SKIPCOUNT}")
  cids+=("${id::12}") #store only the first 12 characters of a container ID
done

dlist="" #docker list
for id in ${cids[@]}; do
  dlist+=" ${id}"
done

#wait until all these dockers are stopped
printf "\n${FUZZER^^}: Fuzzing in progress ..."
printf "\n${FUZZER^^}: Waiting for the following containers to stop: ${dlist}"
if [ "$PROFUZZBENCH_MONITOR" != "0" ]; then
  profuzzbench_monitor_containers "$LABEL" "$TIMEOUT" "${cids[@]}" &
  MONITOR_PID=$!
fi
CONTAINER_STATUS=0
for id in "${cids[@]}"; do
  if ! exit_code=$(docker wait "$id"); then
    printf "\n${FUZZER^^}: Failed to wait for container ${id}"
    CONTAINER_STATUS=1
  elif [[ "$exit_code" != "0" ]]; then
    printf "\n${FUZZER^^}: Container ${id} exited with status ${exit_code}"
    CONTAINER_STATUS=1
  fi
done
profuzzbench_stop_monitor "$MONITOR_PID"
profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"

#collect the fuzzing results from the containers
if ! collect_results; then
  CONTAINER_STATUS=1
fi

if [[ "$CONTAINER_STATUS" != "0" ]]; then
  printf "\n${FUZZER^^}: Completed with failed container(s).\n"
  exit "$CONTAINER_STATUS"
fi

printf "\n${FUZZER^^}: I am done!\n"
