#!/bin/bash

export TARGET_DIR="lighttpd1-stateafl"
export INPUTS=${WORKDIR}/in-http-replay
export STATEAFL_TARGET_BINARY="${WORKDIR}/lighttpd1-stateafl/src/lighttpd"
