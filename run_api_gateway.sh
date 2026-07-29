#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
ACTION=${1:-start}
CONFIG=${VOLTRON_GATEWAY_CONFIG:-"$ROOT/config/voltron-llm.yaml"}
IMAGE=${VOLTRON_GATEWAY_IMAGE:-voltronbench-api-gateway}
CONTAINER=${VOLTRON_GATEWAY_CONTAINER:-voltron-api-gateway}
NETWORK=${VOLTRON_DOCKER_NETWORK:-voltronbench}
HOST_PORT=${VOLTRON_GATEWAY_HOST_PORT:-8000}
TOKEN=${VOLTRON_GATEWAY_TOKEN:-voltronbench-internal}

usage() {
  cat <<'EOF'
Usage: ./run_api_gateway.sh [start|stop|restart|status|logs]

Environment:
  VOLTRON_GATEWAY_CONFIG      Gateway/profile YAML file
  VOLTRON_GATEWAY_TOKEN       Token accepted from experiment containers
  VOLTRON_GATEWAY_HOST_PORT   Host port for status and local clients
  VOLTRON_DOCKER_NETWORK      Docker network shared with LLM client containers
  FORCE_GATEWAY_REBUILD=1     Rebuild the gateway image before starting
EOF
}

container_exists() {
  docker container inspect "$CONTAINER" >/dev/null 2>&1
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]
}

build_image() {
  if [ "${FORCE_GATEWAY_REBUILD:-0}" = "1" ] \
    || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -f "$ROOT/Dockerfile.gateway" -t "$IMAGE" "$ROOT"
  fi
}

start_gateway() {
  if [ ! -r "$CONFIG" ]; then
    echo "Gateway configuration is not readable: $CONFIG" >&2
    exit 1
  fi
  if container_running; then
    echo "API gateway is already running: $CONTAINER"
    return
  fi

  build_image
  if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create "$NETWORK" >/dev/null
  fi
  if container_exists; then
    docker rm "$CONTAINER" >/dev/null
  fi

  docker run -d \
    --name "$CONTAINER" \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p "127.0.0.1:${HOST_PORT}:8000" \
    -e VOLTRON_GATEWAY_CONFIG=/run/secrets/voltron-llm.yaml \
    -e VOLTRON_GATEWAY_TOKEN="$TOKEN" \
    -v "$CONFIG:/run/secrets/voltron-llm.yaml:ro" \
    "$IMAGE" --host 0.0.0.0 --port 8000 >/dev/null

  for _attempt in $(seq 1 30); do
    if docker exec "$CONTAINER" \
      python3 -c \
      'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/healthz", timeout=1)' \
      >/dev/null 2>&1; then
      echo "API gateway started: $CONTAINER"
      return
    fi
    if ! container_running; then
      echo "API gateway exited during startup." >&2
      docker logs "$CONTAINER" >&2 || true
      exit 1
    fi
    sleep 1
  done

  echo "API gateway did not become ready within 30 seconds." >&2
  docker logs "$CONTAINER" >&2 || true
  exit 1
}

stop_gateway() {
  if ! container_exists; then
    echo "API gateway container does not exist: $CONTAINER"
    return
  fi
  if container_running; then
    docker stop "$CONTAINER" >/dev/null
  fi
  echo "API gateway stopped: $CONTAINER"
}

case "$ACTION" in
  start)
    start_gateway
    ;;
  stop)
    stop_gateway
    ;;
  restart)
    stop_gateway
    start_gateway
    ;;
  status)
    if container_running; then
      docker ps --filter "name=^/${CONTAINER}$" \
        --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
    else
      echo "API gateway is not running: $CONTAINER"
      exit 1
    fi
    ;;
  logs)
    docker logs "$CONTAINER"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
