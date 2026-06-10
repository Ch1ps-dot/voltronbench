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
VOLTRON_SOURCE=$("$ROOT/scripts/prepare_voltron.sh")
UV_CACHE=${VOLTRON_UV_CACHE_DIR:-"$ROOT/.runtime/voltron/uv-cache"}

cids=()
mkdir -p "$SAVETO"
mkdir -p "$UV_CACHE"
chmod 0777 "$UV_CACHE"

for i in $(seq 1 "$RUNS"); do
  docker_args=(
    run --cpus=1 -d -it
    --mount "type=bind,src=${VOLTRON_SOURCE},dst=/opt/voltron-src,readonly"
    --mount "type=bind,src=${ROOT}/benchmark/scripts/execution/profuzzbench_voltron_container.sh,dst=/opt/voltron-benchmark-runner.sh,readonly"
    --mount "type=bind,src=${UV_CACHE},dst=/home/ubuntu/.cache/uv"
    -e UV_CACHE_DIR=/home/ubuntu/.cache/uv
    -e UV_PYTHON_INSTALL_DIR=/home/ubuntu/.cache/uv/python
  )
  for env_name in VOLTRON_LLM_BASE_URL VOLTRON_LLM_API_KEY VOLTRON_LLM_MODEL VOLTRON_STATS_INTERVAL; do
    if [ -n "${!env_name:-}" ]; then
      docker_args+=(-e "${env_name}=${!env_name}")
    fi
  done

  id=$(docker "${docker_args[@]}" "$DOCIMAGE" /bin/bash \
    /opt/voltron-benchmark-runner.sh "$TARGET" "$OUTDIR" "$TIMEOUT" "$SKIPCOUNT")
  cids+=("${id::12}")
done

printf "\nVOLTRON: Fuzzing in progress ..."
printf "\nVOLTRON: Waiting for the following containers to stop: %s" "${cids[*]}"
docker wait "${cids[@]}" > /dev/null

printf "\nVOLTRON: Collecting results and saving them to %s" "$SAVETO"
index=1
for id in "${cids[@]}"; do
  printf "\nVOLTRON: Collecting results from container %s" "$id"
  docker cp \
    "${id}:/home/ubuntu/voltron-runtime/${OUTDIR}.tar.gz" \
    "${SAVETO}/${OUTDIR}_${index}.tar.gz" > /dev/null
  if [ -n "$DELETE" ]; then
    docker rm "$id" > /dev/null
  fi
  index=$((index + 1))
done

printf "\nVOLTRON: I am done!\n"
