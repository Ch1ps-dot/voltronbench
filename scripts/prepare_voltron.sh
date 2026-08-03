#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${VOLTRON_REPO:-https://github.com/Ch1ps-dot/voltron.git}
REF=${VOLTRON_REF:-main}
SOURCE_IMAGE=${VOLTRON_SOURCE_IMAGE:-}
SOURCE_IMAGE_PATH=${VOLTRON_SOURCE_IMAGE_PATH:-/opt/voltron-src}
CACHE_ROOT=${VOLTRON_CACHE_DIR:-"$ROOT/.runtime/voltron"}
MIRROR="$CACHE_ROOT/repository.git"
SNAPSHOTS="$CACHE_ROOT/snapshots"

source_tree_is_complete() {
  local source=$1

  [ -f "$source/pyproject.toml" ] \
    && [ -f "$source/cli.py" ] \
    && [ -f "$source/config/configs.yaml" ] \
    && [ -f "$source/voltron/synthesizer/synthesizer.py" ]
}

snapshot_is_ready() {
  local snapshot=$1

  [ -f "$snapshot/.benchmark-ready" ] \
    && source_tree_is_complete "$snapshot"
}

if [ -n "${VOLTRON_SOURCE_DIR:-}" ]; then
  SOURCE=$(cd "$VOLTRON_SOURCE_DIR" && pwd)
  test -f "$SOURCE/pyproject.toml"
  test -f "$SOURCE/cli.py"
  test -f "$SOURCE/config/configs.yaml"
  test -f "$SOURCE/voltron/synthesizer/synthesizer.py"
  printf '%s\n' "$SOURCE"
  exit 0
fi

if [ -n "$SOURCE_IMAGE" ]; then
  case "$SOURCE_IMAGE_PATH" in
    /*) ;;
    *) printf 'VOLTRON_SOURCE_IMAGE_PATH must be absolute.\n' >&2; exit 2 ;;
  esac
  if [[ "$SOURCE_IMAGE" == *$'\n'* || "$SOURCE_IMAGE" == *$'\r'* \
    || "$SOURCE_IMAGE_PATH" == *$'\n'* || "$SOURCE_IMAGE_PATH" == *$'\r'* ]]; then
    printf 'VOLTRON_SOURCE_IMAGE and VOLTRON_SOURCE_IMAGE_PATH must not contain newlines.\n' >&2
    exit 2
  fi
fi

mkdir -p "$CACHE_ROOT" "$SNAPSHOTS"

exec 9>"$CACHE_ROOT/prepare.lock"
flock 9

if [ -n "$SOURCE_IMAGE" ]; then
  printf 'Preparing Voltron source from image %s...\n' "$SOURCE_IMAGE" >&2
  docker pull "$SOURCE_IMAGE" >&2
  IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$SOURCE_IMAGE")
  IMAGE_KEY=${IMAGE_ID#sha256:}
  SNAPSHOT="$SNAPSHOTS/image-$IMAGE_KEY"
  if ! snapshot_is_ready "$SNAPSHOT"; then
    if [ -e "$SNAPSHOT" ]; then
      rm -rf "$SNAPSHOT"
    fi
    TEMP=$(mktemp -d "$SNAPSHOTS/.image-$IMAGE_KEY.XXXXXX")
    CONTAINER=$(docker create "$SOURCE_IMAGE")
    if ! docker cp "$CONTAINER:$SOURCE_IMAGE_PATH/." "$TEMP"; then
      docker rm "$CONTAINER" >/dev/null 2>&1 || true
      rm -rf "$TEMP"
      printf 'Voltron source image is missing %s: %s\n' \
        "$SOURCE_IMAGE_PATH" "$SOURCE_IMAGE" >&2
      exit 1
    fi
    docker rm "$CONTAINER" >/dev/null 2>&1
    if ! source_tree_is_complete "$TEMP"; then
      rm -rf "$TEMP"
      printf 'Voltron source image has an incomplete source tree: %s\n' \
        "$SOURCE_IMAGE" >&2
      exit 1
    fi
    chmod 0755 "$TEMP"
    sed -i 's|^  api_key:.*|  api_key: <set-with-VOLTRON_LLM_API_KEY>|' \
      "$TEMP/config/configs.yaml"
    printf 'image:%s\n' "$IMAGE_ID" > "$TEMP/.benchmark-voltron-commit"
    printf '%s\n' "$SOURCE_IMAGE" > "$TEMP/.benchmark-voltron-source-image"
    touch "$TEMP/.benchmark-ready"
    mv "$TEMP" "$SNAPSHOT"
  fi
  chmod 0755 "$SNAPSHOT"
  printf '%s\n' "$SNAPSHOT"
  exit 0
fi

if [ ! -d "$MIRROR" ]; then
  git clone --mirror "$REPO" "$MIRROR" >&2
else
  git --git-dir="$MIRROR" fetch --prune origin >&2
fi

if ! COMMIT=$(git --git-dir="$MIRROR" rev-parse "${REF}^{commit}" 2>/dev/null); then
  git --git-dir="$MIRROR" fetch --prune origin >&2
  COMMIT=$(git --git-dir="$MIRROR" rev-parse "${REF}^{commit}")
fi
SNAPSHOT="$SNAPSHOTS/$COMMIT"

if ! snapshot_is_ready "$SNAPSHOT"; then
  # The snapshot path is a full Git object ID below our private cache.  A
  # marker on its own is not enough: an interrupted or failed publish can
  # otherwise leave an empty bind-mount source, which Docker creates as an
  # empty directory in the target container.
  if [ -e "$SNAPSHOT" ]; then
    rm -rf "$SNAPSHOT"
  fi
  TEMP=$(mktemp -d "$SNAPSHOTS/.${COMMIT}.XXXXXX")
  git --git-dir="$MIRROR" archive "$COMMIT" | tar -x -C "$TEMP"
  if ! source_tree_is_complete "$TEMP"; then
    rm -rf "$TEMP"
    printf 'Voltron snapshot is missing required runtime files for %s\n' \
      "$COMMIT" >&2
    exit 1
  fi
  # mktemp creates the snapshot root as 0700.  The snapshot is bind-mounted
  # into benchmark containers that commonly run as the unprivileged ubuntu
  # user, so that mode makes the otherwise valid source tree unreadable.
  chmod 0755 "$TEMP"
  sed -i 's|^  api_key:.*|  api_key: <set-with-VOLTRON_LLM_API_KEY>|' \
    "$TEMP/config/configs.yaml"
  printf '%s\n' "$COMMIT" > "$TEMP/.benchmark-voltron-commit"
  touch "$TEMP/.benchmark-ready"
  mv "$TEMP" "$SNAPSHOT"
fi

# Repair snapshots published by older versions of this script, whose mktemp
# root kept mode 0700 and could not be read by the ubuntu user in containers.
chmod 0755 "$SNAPSHOT"

# Older prepared snapshots predate the commit marker.  The object ID is
# already known here, so repair the metadata without rebuilding the snapshot.
if [ ! -s "$SNAPSHOT/.benchmark-voltron-commit" ]; then
  printf '%s\n' "$COMMIT" > "$SNAPSHOT/.benchmark-voltron-commit"
fi

if ! snapshot_is_ready "$SNAPSHOT"; then
  printf 'Voltron snapshot is incomplete after preparation: %s\n' \
    "$SNAPSHOT" >&2
  exit 1
fi

printf '%s\n' "$SNAPSHOT"
