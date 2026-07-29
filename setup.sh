#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PFBENCH="$ROOT/benchmark"
cd "$ROOT"

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
PFBENCH="$PFBENCH" scripts/execution/profuzzbench_build_all.sh

for subject in "${SUBJECTS[@]}"; do
  rm -rf "$subject/aflnet" "$subject/chatafl" "$subject/voltron"
done
