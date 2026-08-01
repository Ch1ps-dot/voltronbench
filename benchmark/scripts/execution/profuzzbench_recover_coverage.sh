#!/usr/bin/env bash

# Recover source-coverage artifacts from the saved corpus of an exited ChatAFL
# or StateAFL container.  The original container is read-only throughout; a
# fresh container created from the original immutable image performs replay.

set -Eeuo pipefail

readonly WORKDIR=/home/ubuntu/experiments
readonly SCRIPT_NAME=${0##*/}

OUTPUT_ROOT="$PWD/coverage-recovery"
SKIPCOUNT=5
REPLAY_TIMEOUT=7200
DRY_RUN=0
KEEP_COLLECTOR=0
declare -a CONTAINER_IDS=()

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options] CONTAINER_ID [CONTAINER_ID ...]

Replays the saved corpus from an exited ChatAFL or StateAFL container in a
fresh collector container made from the same Image ID.  It never starts,
modifies, or removes the source container.

Options:
  --output-root DIR  Directory for recovered packages (default: $OUTPUT_ROOT)
  --skipcount N      Coverage sampling interval (default: 5)
  --replay-timeout N Maximum seconds for one collector replay (default: 7200)
  --keep-collector   Keep the disposable collector container for debugging
  --dry-run          Validate container metadata and print the recovery plan
  -h, --help         Show this help

The source container must be in the exited state and must retain its OUTDIR
with replayable-queue.  This tool supports the nine active benchmark targets
for ChatAFL and StateAFL only.
EOF
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

require_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "expected a positive integer, got: $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output-root)
      [[ "$#" -ge 2 ]] || die "--output-root requires a directory"
      OUTPUT_ROOT=$2
      shift 2
      ;;
    --skipcount)
      [[ "$#" -ge 2 ]] || die "--skipcount requires an integer"
      SKIPCOUNT=$2
      shift 2
      ;;
    --replay-timeout)
      [[ "$#" -ge 2 ]] || die "--replay-timeout requires an integer"
      REPLAY_TIMEOUT=$2
      shift 2
      ;;
    --keep-collector)
      KEEP_COLLECTOR=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      CONTAINER_IDS+=("$@")
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      CONTAINER_IDS+=("$1")
      shift
      ;;
  esac
done

[[ "${#CONTAINER_IDS[@]}" -gt 0 ]] || {
  usage >&2
  exit 2
}
require_positive_integer "$SKIPCOUNT"
require_positive_integer "$REPLAY_TIMEOUT"
command -v docker >/dev/null 2>&1 || die "docker is required"
docker info >/dev/null 2>&1 || die "cannot communicate with the Docker daemon"

container_command() {
  docker inspect --format '{{range .Config.Cmd}}{{printf "%s " .}}{{end}}' "$1"
}

outdir_from_command() {
  local command=$1
  printf '%s\n' "$command" |
    grep -oE 'out-[[:alnum:]-]+-(chatafl|stateafl)' |
    head -n 1 || true
}

raw_path_for() {
  local target=$1
  local target_dir=$2
  local outdir=$3

  case "$target" in
    live555) printf '%s/%s/testProgs/%s\n' "$WORKDIR" "$target_dir" "$outdir" ;;
    forked-daapd) printf '%s/%s\n' "$WORKDIR" "$outdir" ;;
    lightftp) printf '%s/LightFTP/Source/Release/%s\n' "$WORKDIR" "$outdir" ;;
    *) printf '%s/%s/%s\n' "$WORKDIR" "$target_dir" "$outdir" ;;
  esac
}

target_dir_for() {
  local target=$1
  local fuzzer=$2

  if [[ "$fuzzer" == "stateafl" ]]; then
    case "$target" in
      live555) printf 'live-stateafl\n' ;;
      lightftp) printf 'LightFTP-stateafl\n' ;;
      *) printf '%s-stateafl\n' "$target" ;;
    esac
  else
    case "$target" in
      live555) printf 'live\n' ;;
      lightftp) printf 'LightFTP\n' ;;
      *) printf '%s\n' "$target" ;;
    esac
  fi
}

coverage_command() {
  # The command runs only inside a new collector container.  REC_RAW points
  # to a copied corpus, never to the source container filesystem.
  cat <<'EOS'
set -Eeuo pipefail

readonly W=/home/ubuntu/experiments
readonly RAW=$REC_RAW
readonly TARGET=$REC_TARGET
readonly SKIPCOUNT=$REC_SKIPCOUNT

if ! find "$RAW/replayable-queue" -mindepth 1 -type f -print -quit | grep -q .; then
  echo "missing or empty replayable-queue: $RAW/replayable-queue" >&2
  exit 20
fi

rm -f "$RAW/cov_over_time.csv"
rm -rf "$RAW/cov_html"

render_html() {
  local gcov_dir=$1
  shift
  cd "$gcov_dir"
  gcovr "$@" --html --html-details -o index.html
  mkdir -p "$RAW/cov_html"
  cp ./*.html "$RAW/cov_html/"
}

case "$TARGET" in
  live555)
    cd "$W/live-gcov/testProgs"
    cov_script "$RAW" 8554 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    cd "$W/live-gcov"
    for f in BasicUsageEnvironment liveMedia groupsock UsageEnvironment; do
      cp "$f/include/"*.hh "$f/"
    done
    render_html "$W/live-gcov/testProgs" -r ..
    ;;
  kamailio)
    cd "$W"
    cov_script "$RAW" 5060 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/kamailio-gcov" -r .
    ;;
  exim)
    cd "$W/exim-gcov"
    cp ./src/build-Linux-x86_64/exim /usr/exim/bin/exim
    cov_script "$RAW" 25 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/exim-gcov" -r .
    ;;
  forked-daapd)
    /etc/init.d/dbus start
    /etc/init.d/avahi-daemon start
    cd "$W"
    cov_script "$RAW" 3689 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/forked-daapd-gcov" -r .
    ;;
  pure-ftpd)
    cd "$W/pure-ftpd-gcov"
    cov_script "$RAW" 21 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/pure-ftpd-gcov" -r .
    ;;
  proftpd)
    cd "$W/proftpd-gcov"
    cov_script "$RAW" 21 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/proftpd-gcov" -r .
    ;;
  bftpd)
    cd "$W/bftpd-gcov"
    cov_script "$RAW" 21 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/bftpd-gcov" -r .
    ;;
  lightftp)
    cd "$W/LightFTP-gcov/Source/Release"
    cov_script "$RAW" 2200 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/LightFTP-gcov/Source/Release" -r ..
    ;;
  lighttpd1)
    cd "$W/lighttpd1-gcov"
    cov_script "$RAW" 8080 "$SKIPCOUNT" "$RAW/cov_over_time.csv" 1
    render_html "$W/lighttpd1-gcov" -r .. --exclude 'src/t/'
    ;;
  *)
    echo "unsupported target: $TARGET" >&2
    exit 21
    ;;
esac

[[ -s "$RAW/cov_over_time.csv" ]] || {
  echo "coverage CSV was not produced" >&2
  exit 22
}
if ! awk -F, '
  NR > 1 && NF == 5 && $1 ~ /^[0-9]+$/ &&
  $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ &&
  $4 ~ /^[0-9.]+$/ && $5 ~ /^[0-9.]+$/ { found = 1 }
  END { exit !found }
' "$RAW/cov_over_time.csv"; then
  echo "coverage CSV has no valid timestamped sample" >&2
  exit 23
fi
[[ -f "$RAW/cov_html/index.html" ]] || {
  echo "coverage HTML index was not produced" >&2
  exit 24
}
EOS
}

recover_one() {
  local source_id=$1
  local state image_id image_ref command outdir fuzzer target target_dir raw_path
  local case_dir snapshot_dir snapshot_path recovered_dir collector_id csv_path html_path relative_raw_path
  local status=0

  docker inspect "$source_id" >/dev/null 2>&1 || die "container not found: $source_id"
  state=$(docker inspect --format '{{.State.Status}}' "$source_id")
  [[ "$state" == "exited" ]] || die "container $source_id is $state; stop it before recovery"

  image_id=$(docker inspect --format '{{.Image}}' "$source_id")
  image_ref=$(docker inspect --format '{{.Config.Image}}' "$source_id")
  command=$(container_command "$source_id")
  outdir=$(outdir_from_command "$command")
  [[ -n "$outdir" ]] || die "cannot infer an out-<target>-<fuzzer> directory from $source_id"
  fuzzer=${outdir##*-}
  [[ "$fuzzer" == "chatafl" || "$fuzzer" == "stateafl" ]] || \
    die "unsupported fuzzer in $outdir (only chatafl and stateafl are supported)"
  target=${outdir#out-}
  target=${target%-"$fuzzer"}
  target_dir=$(target_dir_for "$target" "$fuzzer")
  raw_path=$(raw_path_for "$target" "$target_dir" "$outdir")

  case "$target" in
    live555|kamailio|exim|forked-daapd|pure-ftpd|proftpd|bftpd|lightftp|lighttpd1) ;;
    *) die "unsupported target inferred from $source_id: $target" ;;
  esac

  printf '\n[%s] target=%s fuzzer=%s image=%s\n' \
    "${source_id:0:12}" "$target" "$fuzzer" "$image_id"
  printf '  source OUTDIR: %s\n' "$raw_path"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  dry run: would copy corpus, create collector, replay coverage, and export a new package\n'
    return 0
  fi

  mkdir -p "$OUTPUT_ROOT"
  case_dir=$(mktemp -d "$OUTPUT_ROOT/coverage-recovery-${source_id:0:12}-XXXXXX")
  snapshot_dir="$case_dir/source-output"
  recovered_dir="$case_dir/recovered-output"
  mkdir -p "$snapshot_dir" "$recovered_dir"
  printf '  recovery directory: %s\n' "$case_dir"

  # docker cp is not reliable for all exited overlay containers.  docker export
  # reads the stopped container root filesystem directly and preserves corpus
  # mtimes when tar extracts it with -p.
  relative_raw_path=${raw_path#/}
  # AFL's ordinary queue may hard-link back to the initial seed directory.
  # Coverage consumes replayable-queue, not queue, so exclude the ordinary
  # queue rather than extracting an unrelated complete container filesystem.
  if ! docker export "$source_id" | tar -xpf - \
      --exclude="$relative_raw_path/queue" \
      -C "$snapshot_dir" "$relative_raw_path"; then
    printf '  source OUTDIR is unavailable; leaving evidence in %s\n' "$case_dir" >&2
    return 1
  fi
  snapshot_path="$snapshot_dir/$relative_raw_path"
  if ! find "$snapshot_path/replayable-queue" -mindepth 1 -type f -print -quit | grep -q .; then
    printf '  replayable-queue is missing or empty; cannot recover source coverage\n' >&2
    return 1
  fi

  collector_id=$(docker run -d \
    --user root \
    --label voltronbench.coverage-recovery=true \
    --label "voltronbench.coverage-source=$source_id" \
    --entrypoint /bin/bash "$image_id" \
    -lc 'while :; do sleep 3600; done')
  printf '  collector: %s\n' "${collector_id:0:12}"

  cleanup_collector() {
    if [[ -n "${collector_id:-}" && "$KEEP_COLLECTOR" != "1" ]]; then
      docker rm -f "$collector_id" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_collector RETURN

  docker cp "$snapshot_path" "$collector_id:$(dirname "$raw_path")"
  if ! coverage_command | timeout --preserve-status "$REPLAY_TIMEOUT" docker exec -i \
      -e "REC_RAW=$raw_path" \
      -e "REC_TARGET=$target" \
      -e "REC_SKIPCOUNT=$SKIPCOUNT" \
      "$collector_id" /bin/bash -lc 'cat >/tmp/recover-coverage.sh && /bin/bash /tmp/recover-coverage.sh' \
      >"$case_dir/coverage-replay.log" 2>&1; then
    status=1
  fi

  if ! docker export "$collector_id" | tar -xpf - -C "$recovered_dir" "$relative_raw_path"; then
    printf '  failed to export collector output; inspect %s/coverage-replay.log\n' "$case_dir" >&2
    return 1
  fi
  local recovered_path="$recovered_dir/$relative_raw_path"
  csv_path="$recovered_path/cov_over_time.csv"
  html_path="$recovered_path/cov_html/index.html"
  if [[ ! -s "$csv_path" || ! -f "$html_path" ]] \
    || ! awk -F, '
      NR > 1 && NF == 5 && $1 ~ /^[0-9]+$/ &&
      $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ &&
      $4 ~ /^[0-9.]+$/ && $5 ~ /^[0-9.]+$/ { found = 1 }
      END { exit !found }
    ' "$csv_path"; then
    status=1
  fi

  {
    printf 'source_container_id=%s\n' "$source_id"
    printf 'source_image_id=%s\n' "$image_id"
    printf 'source_image_ref=%s\n' "$image_ref"
    printf 'target=%s\n' "$target"
    printf 'fuzzer=%s\n' "$fuzzer"
    printf 'outdir=%s\n' "$outdir"
    printf 'raw_path=%s\n' "$raw_path"
    printf 'skipcount=%s\n' "$SKIPCOUNT"
    printf 'replay_timeout_seconds=%s\n' "$REPLAY_TIMEOUT"
    printf 'recovery_status=%s\n' "$([[ "$status" == 0 ]] && echo complete || echo failed)"
  } >"$case_dir/recovery-metadata.txt"
  tar -C "$recovered_dir" -zcf "$case_dir/recovered-${outdir}.tar.gz" "$relative_raw_path"

  if [[ "$status" == 0 ]]; then
    printf '  recovered coverage package: %s\n' "$case_dir/recovered-${outdir}.tar.gz"
  else
    printf '  recovery did not pass validation; inspect %s/coverage-replay.log\n' "$case_dir" >&2
  fi
  return "$status"
}

overall_status=0
for container_id in "${CONTAINER_IDS[@]}"; do
  if ! recover_one "$container_id"; then
    overall_status=1
  fi
done

exit "$overall_status"
