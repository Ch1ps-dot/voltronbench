#!/usr/bin/env bash

# Replay the AFLNet queue stored in a completed Voltron archive in a fresh,
# disposable collector container.  The source archive is never modified.

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
OUTPUT_ROOT="$PWD/coverage-recovery"
ARCHIVE=
TARGET=
IMAGE=
SKIPCOUNT=5
REPLAY_TIMEOUT=7200
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --archive FILE [options]

Replay a Voltron result archive whose root contains replayable-queue/ in a
fresh collector container.  The recovered coverage package is written under
the output root; the archive is read-only.

Options:
  --archive FILE       out-<target>-voltron_<rep>.tar.gz (required)
  --target TARGET      override target inferred from archive
  --image IMAGE        override collector image (default target Voltron image)
  --output-root DIR    directory for recovered packages (default coverage-recovery)
  --skipcount N        coverage sampling interval (default 5)
  --replay-timeout N   seconds allowed for coverage replay (default 7200)
  --dry-run            validate archive and print the recovery plan
  -h, --help           show this help
EOF
}

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    --target) TARGET=${2:-}; shift 2 ;;
    --image) IMAGE=${2:-}; shift 2 ;;
    --output-root) OUTPUT_ROOT=${2:-}; shift 2 ;;
    --skipcount) SKIPCOUNT=${2:-}; shift 2 ;;
    --replay-timeout) REPLAY_TIMEOUT=${2:-}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "--archive must name a readable file"
[[ "$SKIPCOUNT" =~ ^[1-9][0-9]*$ ]] || die "--skipcount must be a positive integer"
[[ "$REPLAY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--replay-timeout must be a positive integer"
command -v docker >/dev/null 2>&1 || die "docker is required"

first_archive_root() (
  # tar exits with SIGPIPE after awk finds the first member; deliberately use
  # awk's status here rather than treating that normal short-read as failure.
  set +o pipefail
  tar -tzf "$ARCHIVE" | awk -F/ 'NF > 1 { print $1; exit }'
)

archive_has_member() (
  set +o pipefail
  tar -tzf "$ARCHIVE" | grep -q "$1"
)

root=$(first_archive_root)
[[ "$root" =~ ^out-[A-Za-z0-9-]+-voltron$ ]] || die "cannot infer Voltron result root from archive"
inferred_target=${root#out-}
inferred_target=${inferred_target%-voltron}
TARGET=${TARGET:-$inferred_target}
[[ "$TARGET" == "$inferred_target" ]] || die "--target does not match archive root $root"

case "$TARGET" in
  exim|forked-daapd|kamailio|lightftp|lighttpd1|live555|proftpd|pure-ftpd|bftpd) ;;
  *) die "unsupported target: $TARGET" ;;
esac

if [[ -z "$IMAGE" ]]; then
  case "$TARGET" in
    lighttpd1) IMAGE=lighttpd1-vol:latest ;;
    *) IMAGE="${TARGET}-voltron:latest" ;;
  esac
fi

if ! archive_has_member "^${root}/replayable-queue/"; then
  die "archive has no replayable-queue; run fuzz-only/full collection with queue export first"
fi

archive_sha256=$(sha256sum "$ARCHIVE" | awk '{print $1}')
if [[ "$DRY_RUN" == 1 ]]; then
  printf 'target=%s\nimage=%s\narchive_sha256=%s\n' "$TARGET" "$IMAGE" "$archive_sha256"
  exit 0
fi

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "collector image is unavailable: $IMAGE"
mkdir -p "$OUTPUT_ROOT"
case_dir=$(mktemp -d "$OUTPUT_ROOT/voltron-coverage-${TARGET}-XXXXXX")
raw_dir="$case_dir/source-output/$root"
mkdir -p "$raw_dir"

cleanup() {
  [[ -n "${collector_id:-}" ]] && docker rm -f "$collector_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Only extract the immutable replay corpus and its manifest; avoid restoring
# arbitrary result artifacts into the recovery workspace.
tar -xzf "$ARCHIVE" -C "$case_dir/source-output" \
  "${root}/replayable-queue" \
  "${root}/voltron_aflnet_replay_manifest.csv" 2>/dev/null || \
  tar -xzf "$ARCHIVE" -C "$case_dir/source-output" "${root}/replayable-queue"

find "$raw_dir/replayable-queue" -mindepth 1 -type f -print -quit | grep -q . || \
  die "replayable-queue is empty"

collector_id=$(docker run --init -d --user root \
  --label voltronbench.coverage-recovery=true \
  --label "voltronbench.coverage-source-sha256=$archive_sha256" \
  -v "$raw_dir:/recovery:rw" \
  --entrypoint /bin/bash "$IMAGE" -lc 'while :; do sleep 3600; done')

printf 'target=%s\nimage=%s\narchive=%s\narchive_sha256=%s\n' \
  "$TARGET" "$IMAGE" "$ARCHIVE" "$archive_sha256" > "$case_dir/provenance.txt"

if ! timeout --preserve-status "$REPLAY_TIMEOUT" docker exec "$collector_id" \
  /bin/bash /opt/voltron-coverage.sh "$TARGET" /recovery "$SKIPCOUNT" \
  >"$case_dir/coverage-replay.log" 2>&1; then
  printf 'coverage replay failed; see %s\n' "$case_dir/coverage-replay.log" >&2
  exit 1
fi

[[ -s "$raw_dir/cov_over_time.csv" ]] || die "coverage replay did not produce cov_over_time.csv"
tar -C "$case_dir" -zcf "$case_dir/recovered-coverage.tar.gz" source-output provenance.txt coverage-replay.log
sha256sum "$case_dir/recovered-coverage.tar.gz" > "$case_dir/recovered-coverage.tar.gz.sha256"
printf 'recovered_package=%s\n' "$case_dir/recovered-coverage.tar.gz"
