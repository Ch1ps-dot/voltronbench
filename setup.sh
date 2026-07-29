#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PFBENCH="$ROOT/benchmark"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--github-mirror URL_PREFIX | --github-direct]

Options:
  --github-mirror URL_PREFIX  Prefix complete GitHub clone URLs with a trusted
                              mirror, for example:
                              https://mirror.example/https://github.com/...
  --github-direct             Use https://github.com directly, overriding
                              GITHUB_MIRROR from the environment.
  -h, --help                  Show this help.

Environment:
  GITHUB_MIRROR               Same URL prefix accepted by --github-mirror.
  FORCE_REBUILD=1             Rebuild images that already exist.
EOF
}

GITHUB_MIRROR=${GITHUB_MIRROR:-}
while (($# > 0)); do
  case "$1" in
    --github-mirror)
      if (($# < 2)); then
        echo "--github-mirror requires a URL prefix." >&2
        usage >&2
        exit 2
      fi
      GITHUB_MIRROR=$2
      shift 2
      ;;
    --github-mirror=*)
      GITHUB_MIRROR=${1#*=}
      shift
      ;;
    --github-direct)
      GITHUB_MIRROR=
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown setup option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$GITHUB_MIRROR" == *$'\n'* \
  || "$GITHUB_MIRROR" == *$'\r'* ]]; then
  echo "GITHUB_MIRROR must not contain a newline." >&2
  exit 2
fi
if [[ -n "$GITHUB_MIRROR" ]]; then
  case "$GITHUB_MIRROR" in
    http://*|https://*) ;;
    *)
      echo "GITHUB_MIRROR must be an HTTP(S) URL prefix." >&2
      exit 2
      ;;
  esac
  GITHUB_MIRROR_AUTHORITY=${GITHUB_MIRROR#*://}
  GITHUB_MIRROR_AUTHORITY=${GITHUB_MIRROR_AUTHORITY%%/*}
  if [[ "$GITHUB_MIRROR_AUTHORITY" == *"@"* ]]; then
    echo "GITHUB_MIRROR must not contain embedded credentials." >&2
    exit 2
  fi
  if [[ "$GITHUB_MIRROR" == *"?"* || "$GITHUB_MIRROR" == *"#"* ]]; then
    echo "GITHUB_MIRROR must not contain a query string or fragment." >&2
    exit 2
  fi
  GITHUB_MIRROR="${GITHUB_MIRROR%/}/"
  printf 'GitHub source mode: mirror prefix %s\n' "$GITHUB_MIRROR"
else
  echo "GitHub source mode: direct https://github.com"
fi
export GITHUB_MIRROR

# ChatAFL model, URL, and API key are selected at container runtime.

SUBJECTS=(
  "$PFBENCH/subjects/RTSP/Live555"
  "$PFBENCH/subjects/SIP/Kamailio"
  "$PFBENCH/subjects/SMTP/Exim"
  "$PFBENCH/subjects/DAAP/forked-daapd"
  "$PFBENCH/subjects/FTP/PureFTPD"
  "$PFBENCH/subjects/FTP/ProFTPD"
  "$PFBENCH/subjects/FTP/BFTPD"
  "$PFBENCH/subjects/FTP/LightFTP"
  "$PFBENCH/subjects/HTTP/Lighttpd1"
)

# Copy AFLNet and ChatAFL into the active target build contexts.
for subject in "${SUBJECTS[@]}"; do
  rm -rf "$subject/aflnet" "$subject/chatafl" "$subject/voltron"
  cp -r "$ROOT/aflnet" "$subject/aflnet"
  cp -r "$ROOT/ChatAFL" "$subject/chatafl"
done

# Build the docker images

cd "$PFBENCH"
GITHUB_MIRROR="$GITHUB_MIRROR" \
PFBENCH="$PFBENCH" \
scripts/execution/profuzzbench_build_all.sh

for subject in "${SUBJECTS[@]}"; do
  rm -rf "$subject/aflnet" "$subject/chatafl" "$subject/voltron"
done
