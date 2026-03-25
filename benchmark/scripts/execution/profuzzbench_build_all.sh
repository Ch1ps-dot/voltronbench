#!/bin/bash

#export NO_CACHE="--no-cache"
#export MAKE_OPT="-j4"

# Build a docker image only if it does not already exist.
# Arguments:
#   $1: path to build context (relative to PFBENCH)
#   $2: docker image tag
build_if_missing() {
  local ctx="$1"
  local tag="$2"

  if docker image inspect "$tag" > /dev/null 2>&1; then
    echo "docker image '$tag' already exists; skipping build"
    return 0
  fi

  echo "building $tag"
  (cd "$PFBENCH" && cd "$ctx" && docker build . -t "$tag" --build-arg MAKE_OPT $NO_CACHE)
}

build_if_missing "subjects/DNS/Dnsmasq" dnsmasq-vol
build_if_missing "subjects/DTLS/TinyDTLS" tinydtls-vol
build_if_missing "subjects/SSH/OpenSSH" openssh-vol
build_if_missing "subjects/TLS/OpenSSL" openssl-vol
build_if_missing "subjects/FTP/LightFTP" lightftp-vol
build_if_missing "subjects/FTP/BFTPD" bftpd-vol
build_if_missing "subjects/FTP/ProFTPD" proftpd-vol
build_if_missing "subjects/FTP/PureFTPD" pure-ftpd-vol
build_if_missing "subjects/SMTP/Exim" exim-vol
build_if_missing "subjects/RTSP/Live555" live555-vol
build_if_missing "subjects/SIP/Kamailio" kamailio-vol
build_if_missing "subjects/DAAP/forked-daapd" forked-daapd-vol
build_if_missing "subjects/HTTP/Lighttpd1" lighttpd1-vol
build_if_missing "subjects/DICOM/Dcmtk" dcmtk-vol
