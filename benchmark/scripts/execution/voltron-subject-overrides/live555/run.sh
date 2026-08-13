#!/bin/bash
set -eu

# The Live555 server resolves requested media names relative to its CWD.  Its
# sample corpus is installed beside testOnDemandRTSPServer in the benchmark
# image, not in Voltron's copied runtime checkout.
cd /home/ubuntu/experiments/live/testProgs

for media in test.aac test.ac3 test.mpg; do
  if [ ! -r "$media" ]; then
    printf 'Live555 startup preflight failed: missing sample media %s in %s\n' \
      "$media" "$PWD" >&2
    exit 2
  fi
done

exec ./testOnDemandRTSPServer 8554
