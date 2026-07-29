#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILDER_IMAGE=${1:-${CHATAFL_BUILDER_IMAGE:-lightftp-vol}}
CACHE_ROOT=${CHATAFL_CACHE_DIR:-"$ROOT/.runtime/chatafl"}
ARTIFACTS_ROOT="$CACHE_ROOT/artifacts"

if ! BUILDER_IMAGE_ID=$(docker image inspect \
  --format '{{.Id}}' "$BUILDER_IMAGE" 2>/dev/null); then
  printf 'ChatAFL builder image is unavailable: %s\n' "$BUILDER_IMAGE" >&2
  printf 'Build the benchmark images first with ./setup.sh, or set CHATAFL_BUILDER_IMAGE.\n' >&2
  exit 1
fi

SOURCE_SHA256=$(
  cd "$ROOT/ChatAFL"
  sha256sum chat-llm.c chatafl-runtime-config.h \
    | sha256sum \
    | cut -d ' ' -f 1
)
IMAGE_CACHE_ID=${BUILDER_IMAGE_ID#sha256:}
CACHE_KEY="${SOURCE_SHA256}-${IMAGE_CACHE_ID}"
ARTIFACT_DIR="$ARTIFACTS_ROOT/$CACHE_KEY"
RUNTIME_BINARY="$ARTIFACT_DIR/afl-fuzz"
METADATA_FILE="$ARTIFACT_DIR/metadata.txt"

mkdir -p "$ARTIFACTS_ROOT"
exec 9>"$CACHE_ROOT/prepare.lock"
flock 9

if [[ -x "$RUNTIME_BINARY" && -f "$METADATA_FILE" ]]; then
  printf '%s\n' "$RUNTIME_BINARY"
  exit 0
fi

TEMP_DIR=$(mktemp -d "$ARTIFACTS_ROOT/.${CACHE_KEY}.XXXXXX")
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

printf 'Preparing ChatAFL runtime with existing image %s...\n' \
  "$BUILDER_IMAGE" >&2
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$ROOT/ChatAFL,dst=/opt/voltronbench-chatafl,readonly" \
  --mount "type=bind,src=$TEMP_DIR,dst=/opt/chatafl-runtime-output" \
  "$BUILDER_IMAGE" \
  /bin/bash -euc '
    cp -a /home/ubuntu/chatafl /tmp/chatafl-runtime-source
    cp /opt/voltronbench-chatafl/chat-llm.c \
      /tmp/chatafl-runtime-source/chat-llm.c
    cp /opt/voltronbench-chatafl/chatafl-runtime-config.h \
      /tmp/chatafl-runtime-source/chatafl-runtime-config.h
    cd /tmp/chatafl-runtime-source
    rm -f afl-fuzz chat-llm.o
    make afl-fuzz
    install -m 0755 afl-fuzz /opt/chatafl-runtime-output/afl-fuzz
    sed -n '"'"'s/^#define MODEL "\(.*\)"$/\1/p'"'"' chat-llm.h \
      | head -n 1 > /opt/chatafl-runtime-output/default-model
    sed -n '"'"'s/^#define URL "\(.*\)"$/\1/p'"'"' chat-llm.h \
      | head -n 1 > /opt/chatafl-runtime-output/default-url
  ' >&2

if [[ ! -x "$TEMP_DIR/afl-fuzz" ]]; then
  printf 'ChatAFL runtime build did not produce afl-fuzz.\n' >&2
  exit 1
fi

DEFAULT_MODEL=$(<"$TEMP_DIR/default-model")
DEFAULT_URL=$(<"$TEMP_DIR/default-url")
if [[ -z "$DEFAULT_MODEL" ]]; then
  printf 'Unable to determine the ChatAFL model compiled into %s.\n' \
    "$BUILDER_IMAGE" >&2
  exit 1
fi
if [[ "$DEFAULT_MODEL" == *$'\n'* || "$DEFAULT_MODEL" == *$'\r'* ]]; then
  printf 'The ChatAFL default model contains an invalid newline.\n' >&2
  exit 1
fi
if [[ -z "$DEFAULT_URL" ]]; then
  printf 'Unable to determine the ChatAFL URL compiled into %s.\n' \
    "$BUILDER_IMAGE" >&2
  exit 1
fi
if [[ "$DEFAULT_URL" == *$'\n'* || "$DEFAULT_URL" == *$'\r'* ]]; then
  printf 'The ChatAFL default URL contains an invalid newline.\n' >&2
  exit 1
fi

BINARY_SHA256=$(sha256sum "$TEMP_DIR/afl-fuzz" | cut -d ' ' -f 1)
{
  printf 'builder_image=%s\n' "$BUILDER_IMAGE"
  printf 'builder_image_id=%s\n' "$BUILDER_IMAGE_ID"
  printf 'runtime_source_sha256=%s\n' "$SOURCE_SHA256"
  printf 'runtime_binary_sha256=%s\n' "$BINARY_SHA256"
  printf 'compiled_default_model=%s\n' "$DEFAULT_MODEL"
  printf 'compiled_default_url=%s\n' "$DEFAULT_URL"
} > "$TEMP_DIR/metadata.txt"
rm -f "$TEMP_DIR/default-model" "$TEMP_DIR/default-url"

if [[ -e "$ARTIFACT_DIR" || -L "$ARTIFACT_DIR" ]]; then
  rm -rf -- "$ARTIFACT_DIR"
fi
if ! mv "$TEMP_DIR" "$ARTIFACT_DIR"; then
  printf 'Unable to install the ChatAFL runtime cache at %s.\n' \
    "$ARTIFACT_DIR" >&2
  exit 1
fi

printf '%s\n' "$RUNTIME_BINARY"
