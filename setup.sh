#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PFBENCH="$ROOT/benchmark"
cd "$ROOT"

# ChatAFL settings are optional and supplied by the environment.
if [ -n "${CHATAFL_MODEL:-}" ]; then
  sed -i "s/#define MODEL \".*\"/#define MODEL \"$CHATAFL_MODEL\"/" ChatAFL/chat-llm.h
fi
if [ -n "${CHATAFL_URL:-}" ]; then
  sed -i "s|#define URL \".*\"|#define URL \"$CHATAFL_URL\"|" ChatAFL/chat-llm.h
fi
if [ -n "${CHATAFL_API_KEY:-}" ]; then
  sed -i "s/#define OPENAI_TOKEN \".*\"/#define OPENAI_TOKEN \"$CHATAFL_API_KEY\"/" ChatAFL/chat-llm.h
fi

# Copy the different versions of ChatAFL to the benchmark directories
for subject in "$PFBENCH"/subjects/*/*; do
  rm -rf "$subject/aflnet" "$subject/chatafl" "$subject/voltron"
  cp -r "$ROOT/aflnet" "$subject/aflnet"
  cp -r "$ROOT/ChatAFL" "$subject/chatafl"
done

# Build the docker images

cd "$PFBENCH"
PFBENCH="$PFBENCH" scripts/execution/profuzzbench_build_all.sh

for subject in "$PFBENCH"/subjects/*/*; do
  rm -rf "$subject/aflnet" "$subject/chatafl" "$subject/voltron"
done
