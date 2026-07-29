#!/bin/bash

set -euo pipefail

#export NO_CACHE="--no-cache"
#export MAKE_OPT="-j4"

# Build a docker image only if it does not already exist.
# Arguments:
#   $1: path to build context (relative to PFBENCH)
#   $2: docker image tag
#   $3: Dockerfile name (optional, defaults to Dockerfile)
build_if_missing() {
  local ctx="$1"
  local tag="$2"
  local dockerfile="${3:-Dockerfile}"

  if [[ -z "${FORCE_REBUILD:-}" ]] && docker image inspect "$tag" > /dev/null 2>&1; then
    echo "docker image '$tag' already exists; skipping build"
    return 0
  fi

  echo "building $tag"
  (cd "$PFBENCH" && cd "$ctx" && docker build . -f "$dockerfile" -t "$tag" \
    --build-arg "MAKE_OPT=${MAKE_OPT:-}" \
    --build-arg "GITHUB_MIRROR=${GITHUB_MIRROR:-}" \
    ${NO_CACHE:-})
}

build_if_missing "subjects/FTP/LightFTP" lightftp-vol
build_if_missing "subjects/FTP/BFTPD" bftpd-vol
build_if_missing "subjects/FTP/ProFTPD" proftpd-vol
build_if_missing "subjects/FTP/PureFTPD" pure-ftpd-vol
build_if_missing "subjects/SMTP/Exim" exim-vol
build_if_missing "subjects/RTSP/Live555" live555-vol
build_if_missing "subjects/SIP/Kamailio" kamailio-vol
build_if_missing "subjects/DAAP/forked-daapd" forked-daapd-vol
build_if_missing "subjects/HTTP/Lighttpd1" lighttpd1-vol

# StateAFL requires a separately instrumented build of each supported target.
# These images layer on top of the corresponding *-vol base image above.
build_if_missing "subjects/FTP/LightFTP" lightftp-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/FTP/BFTPD" bftpd-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/FTP/ProFTPD" proftpd-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/FTP/PureFTPD" pure-ftpd-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/SMTP/Exim" exim-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/RTSP/Live555" live555-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/SIP/Kamailio" kamailio-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/DAAP/forked-daapd" forked-daapd-stateafl-vol Dockerfile-stateafl
build_if_missing "subjects/HTTP/Lighttpd1" lighttpd1-stateafl-vol Dockerfile-stateafl
