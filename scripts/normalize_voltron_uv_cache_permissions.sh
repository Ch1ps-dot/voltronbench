#!/bin/bash

set -eu

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s UV_CACHE_DIRECTORY\n' "$0" >&2
  exit 2
fi

cache_dir=$1

if [ ! -d "$cache_dir" ]; then
  printf 'VOLTRON: uv cache directory is missing: %s\n' "$cache_dir" >&2
  exit 2
fi

# Private cache instances are bind-mounted into images whose default user is
# not consistent: some run as root while others run as ubuntu (UID 1000).
# The host user cannot portably chown files to a container-only UID, so make
# the complete private cache tree writable before publishing it.  The cache
# contains only downloaded Python/runtime artifacts and is isolated by run ID.
chmod -R a+rwX -- "$cache_dir"

unwritable=$(find "$cache_dir" -xdev \
  \( -type d ! -perm -0003 -o -type f ! -perm -0002 \) \
  -print -quit)
if [ -n "$unwritable" ]; then
  printf 'VOLTRON: uv cache path is not writable by container users: %s\n' \
    "$unwritable" >&2
  exit 1
fi
