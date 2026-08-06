#!/bin/bash

set -eu

if [ "$#" -ne 2 ]; then
  printf 'Usage: %s DOCKER_IMAGE VOLTRON_SOURCE\n' "$0" >&2
  exit 2
fi

DOCIMAGE=$1
VOLTRON_SOURCE=$2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UV_CACHE_ROOT=${VOLTRON_UV_CACHE_ROOT:-"$ROOT/.runtime/voltron/uv-cache"}
UV_CACHE_TEMPLATE=${VOLTRON_UV_CACHE_TEMPLATE:-"$ROOT/.runtime/voltron/uv-cache-template"}
LOCK_FILE="${UV_CACHE_TEMPLATE}.lock"

if [ ! -d "$VOLTRON_SOURCE" ]; then
  printf 'VOLTRON: prepared source directory is missing: %s\n' \
    "$VOLTRON_SOURCE" >&2
  exit 2
fi

mkdir -p "$UV_CACHE_ROOT" "$(dirname "$UV_CACHE_TEMPLATE")"
exec 9>"$LOCK_FILE"
flock 9

if [ -f "$UV_CACHE_TEMPLATE/.ready" ]; then
  printf 'VOLTRON: reusing prewarmed uv cache template: %s\n' \
    "$UV_CACHE_TEMPLATE"
  exit 0
fi

temporary=$(mktemp -d "${UV_CACHE_TEMPLATE}.tmp.XXXXXX")
chmod 0777 "$temporary"
published=0

cleanup() {
  if [ "$published" -eq 0 ] && [ -d "$temporary" ]; then
    failed="${UV_CACHE_TEMPLATE}.failed.$(date +%s).$$"
    mv "$temporary" "$failed" 2>/dev/null || true
    printf 'VOLTRON: incomplete uv cache retained at %s\n' "$failed" >&2
  fi
}
trap cleanup EXIT

printf 'VOLTRON: prewarming Python and dependencies once in %s\n' "$DOCIMAGE"
docker run --rm --init --cpus=1 \
  --mount "type=bind,src=${VOLTRON_SOURCE},dst=/opt/voltron-src,readonly" \
  --mount "type=bind,src=${temporary},dst=/home/ubuntu/.cache/uv" \
  -e UV_CACHE_DIR=/home/ubuntu/.cache/uv \
  -e UV_PYTHON_INSTALL_DIR=/home/ubuntu/.cache/uv/python \
  "$DOCIMAGE" /bin/bash -lc '
    set -eu
    runtime=$(mktemp -d /tmp/voltron-cache-prewarm.XXXXXX)
    cp -a /opt/voltron-src/. "$runtime/"
    cd "$runtime"
    uv sync --locked
    uv run python -c "import aalpy, lxml, numpy, openai"
  '

printf 'python=3.14.6\nprepared_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$temporary/.ready"

if [ -e "$UV_CACHE_TEMPLATE" ]; then
  previous="${UV_CACHE_TEMPLATE}.incomplete.$(date +%s).$$"
  mv "$UV_CACHE_TEMPLATE" "$previous"
  printf 'VOLTRON: previous incomplete cache retained at %s\n' "$previous" >&2
fi
mv "$temporary" "$UV_CACHE_TEMPLATE"
published=1
trap - EXIT
printf 'VOLTRON: uv cache template is ready: %s\n' "$UV_CACHE_TEMPLATE"
