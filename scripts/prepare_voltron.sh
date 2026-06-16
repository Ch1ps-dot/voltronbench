#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=${VOLTRON_REPO:-https://github.com/Ch1ps-dot/voltron.git}
REF=${VOLTRON_REF:-main}
CACHE_ROOT=${VOLTRON_CACHE_DIR:-"$ROOT/.runtime/voltron"}
MIRROR="$CACHE_ROOT/repository.git"
SNAPSHOTS="$CACHE_ROOT/snapshots"

if [ -n "${VOLTRON_SOURCE_DIR:-}" ]; then
  SOURCE=$(cd "$VOLTRON_SOURCE_DIR" && pwd)
  test -f "$SOURCE/pyproject.toml"
  test -f "$SOURCE/cli.py"
  printf '%s\n' "$SOURCE"
  exit 0
fi

mkdir -p "$CACHE_ROOT" "$SNAPSHOTS"

exec 9>"$CACHE_ROOT/prepare.lock"
flock 9

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

if [ ! -f "$SNAPSHOT/.benchmark-ready" ]; then
  TEMP=$(mktemp -d "$SNAPSHOTS/.${COMMIT}.XXXXXX")
  git --git-dir="$MIRROR" archive "$COMMIT" | tar -x -C "$TEMP"
  sed -i 's|^  api_key:.*|  api_key: <set-with-VOLTRON_LLM_API_KEY>|' \
    "$TEMP/config/configs.yaml"
  touch "$TEMP/.benchmark-ready"

  if ! mv "$TEMP" "$SNAPSHOT" 2>/dev/null; then
    rm -rf "$TEMP"
  fi
fi

printf '%s\n' "$SNAPSHOT"
