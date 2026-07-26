#!/bin/bash

set -u

IMAGES=(
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
REMOVE_CONTAINERS=1

usage() {
  cat <<'EOF'
Usage: ./clean_images.sh [--dry-run] [--keep-containers]

Remove Docker images built by this benchmark project.

Options:
  --dry-run          Print the containers/images that would be removed.
  --keep-containers  Do not stop or remove containers before removing images.
  -h, --help         Show this help text.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --keep-containers)
      REMOVE_CONTAINERS=0
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

run_or_print() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

remove_containers_for_image() {
  local image=$1
  local containers

  containers=$(docker ps -a -q --filter "ancestor=${image}:latest")
  if [ -z "$containers" ]; then
    return 0
  fi

  echo "Removing containers created from ${image}: ${containers}"
  run_or_print docker stop $containers >/dev/null 2>&1 || true
  run_or_print docker rm $containers >/dev/null 2>&1 || true
}

remove_image() {
  local image=$1

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Image not found, skipping: ${image}"
    return 0
  fi

  echo "Removing image: ${image}"
  run_or_print docker rmi "$image" >/dev/null 2>&1 || {
    echo "Failed to remove image: ${image}" >&2
    return 1
  }
}

FAILED=0
for image in "${IMAGES[@]}"; do
  if [ "$REMOVE_CONTAINERS" = "1" ]; then
    remove_containers_for_image "$image"
  fi
  remove_image "$image" || FAILED=1
done

if [ "$FAILED" = "0" ]; then
  echo "Project Docker image cleanup complete."
else
  echo "Project Docker image cleanup completed with failures." >&2
fi

exit "$FAILED"
