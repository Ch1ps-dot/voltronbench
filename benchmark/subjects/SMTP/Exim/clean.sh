#!/bin/bash

set -u

PIDFILE=/var/lock/exim.pid

if [[ ! -s "$PIDFILE" ]]; then
  rm -f -- "$PIDFILE"
  exit 0
fi

read -r pid _ < "$PIDFILE" || pid=

if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/$pid/comm" ]] && [[ "$(<"/proc/$pid/comm")" == "exim" ]]; then
  kill "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
fi

rm -f -- "$PIDFILE"
