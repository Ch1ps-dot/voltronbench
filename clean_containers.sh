#!/bin/bash

set -euo pipefail

IMAGES=(
  voltronbench-api-gateway
  lightftp-vol
  bftpd-vol
  proftpd-vol
  pure-ftpd-vol
  exim-vol
  live555-vol
  kamailio-vol
  forked-daapd-vol
  lighttpd1-vol
  lightftp-stateafl-vol
  bftpd-stateafl-vol
  proftpd-stateafl-vol
  pure-ftpd-stateafl-vol
  exim-stateafl-vol
  live555-stateafl-vol
  kamailio-stateafl-vol
  forked-daapd-stateafl-vol
  lighttpd1-stateafl-vol
)

DRY_RUN=0
STOP_TIMEOUT=10

usage() {
  cat <<'EOF'
Usage: ./clean_containers.sh [--dry-run] [--timeout SECONDS]

Stop running Docker containers created from VoltronBench experiment images.
Containers are not removed, so their logs and result files remain available.

Options:
  --dry-run          List matching containers without stopping them.
  --timeout SECONDS  Wait this many seconds before Docker sends SIGKILL
                     (default: 10).
  -h, --help         Show this help text.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --timeout)
      if [ "$#" -lt 2 ]; then
        echo "Missing value for --timeout." >&2
        usage >&2
        exit 2
      fi
      STOP_TIMEOUT=$2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$STOP_TIMEOUT" in
  ''|*[!0-9]*)
    echo "--timeout must be a non-negative integer." >&2
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or is not available in PATH." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Cannot connect to the Docker daemon." >&2
  exit 1
fi

container_ids=()
for image in "${IMAGES[@]}"; do
  while IFS= read -r id; do
    if [ -n "$id" ]; then
      container_ids+=("$id")
    fi
  done < <(docker ps -q --filter "ancestor=${image}:latest")
done

if [ "${#container_ids[@]}" -eq 0 ]; then
  echo "No running VoltronBench experiment containers found."
  exit 0
fi

mapfile -t container_ids < <(printf '%s\n' "${container_ids[@]}" | sort -u)

echo "Running VoltronBench experiment containers:"
for id in "${container_ids[@]}"; do
  docker ps \
    --filter "id=${id}" \
    --format '  {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}'
done

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run: no containers were stopped."
  exit 0
fi

echo "Stopping ${#container_ids[@]} container(s) with timeout ${STOP_TIMEOUT}s..."
docker stop --time "$STOP_TIMEOUT" "${container_ids[@]}" >/dev/null
echo "VoltronBench experiment containers stopped. Containers were not removed."
