#!/bin/bash

set -u

TARGET_BINARY=${1:?Usage: preflight TARGET_BINARY CONFIG LOG_FILE}
TARGET_CONFIG=${2:?Usage: preflight TARGET_BINARY CONFIG LOG_FILE}
LOG_FILE=${3:?Usage: preflight TARGET_BINARY CONFIG LOG_FILE}

PREFLIGHT_HOST=${FORKED_DAAPD_PREFLIGHT_HOST:-127.0.0.1}
PREFLIGHT_PORT=${FORKED_DAAPD_PREFLIGHT_PORT:-3689}
PREFLIGHT_ATTEMPTS=${FORKED_DAAPD_PREFLIGHT_ATTEMPTS:-100}
PREFLIGHT_INTERVAL_SECONDS=${FORKED_DAAPD_PREFLIGHT_INTERVAL_SECONDS:-0.1}
PREFLIGHT_RESPONSE_TIMEOUT_SECONDS=${FORKED_DAAPD_PREFLIGHT_RESPONSE_TIMEOUT_SECONDS:-2}
TARGET_PID=

record() {
  printf '%s=%s\n' "$1" "$2" | tee -a "$LOG_FILE"
}

stop_target() {
  local attempt

  if [[ -z "$TARGET_PID" ]]; then
    return 0
  fi

  if kill -0 "$TARGET_PID" 2>/dev/null; then
    kill -TERM "$TARGET_PID" 2>/dev/null || true
    for attempt in $(seq 1 50); do
      if ! kill -0 "$TARGET_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
  fi
  if kill -0 "$TARGET_PID" 2>/dev/null; then
    record target_stop_escalated true
    kill -KILL "$TARGET_PID" 2>/dev/null || true
  fi
  wait "$TARGET_PID" 2>/dev/null || true
  TARGET_PID=
}

handle_signal() {
  stop_target
  exit 130
}

trap handle_signal INT TERM

: > "$LOG_FILE"
record preflight_started_at "$(date --iso-8601=seconds)"
record target_binary "$TARGET_BINARY"
record target_config "$TARGET_CONFIG"
record target_endpoint "${PREFLIGHT_HOST}:${PREFLIGHT_PORT}"

if [[ ! -x "$TARGET_BINARY" ]]; then
  record preflight_status target_binary_not_executable
  exit 2
fi
if [[ ! -r "$TARGET_CONFIG" ]]; then
  record preflight_status target_config_not_readable
  exit 2
fi
if ! command -v nc >/dev/null 2>&1; then
  record preflight_status netcat_not_found
  exit 2
fi
if nc -z "$PREFLIGHT_HOST" "$PREFLIGHT_PORT" >/dev/null 2>&1; then
  record preflight_status port_in_use_before_start
  exit 3
fi

"$TARGET_BINARY" -d 0 -c "$TARGET_CONFIG" -f >> "$LOG_FILE" 2>&1 &
TARGET_PID=$!
record target_pid "$TARGET_PID"

ready=0
for attempt in $(seq 1 "$PREFLIGHT_ATTEMPTS"); do
  if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    record preflight_status target_exited_before_ready
    stop_target
    exit 4
  fi
  if nc -z "$PREFLIGHT_HOST" "$PREFLIGHT_PORT" >/dev/null 2>&1; then
    ready=1
    record ready_attempt "$attempt"
    break
  fi
  sleep "$PREFLIGHT_INTERVAL_SECONDS"
done

if [[ "$ready" != 1 ]]; then
  record preflight_status port_not_ready
  stop_target
  exit 5
fi

status_line=$(
  printf 'GET /api/config HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' \
    "$PREFLIGHT_HOST" \
    | nc -w "$PREFLIGHT_RESPONSE_TIMEOUT_SECONDS" \
        "$PREFLIGHT_HOST" "$PREFLIGHT_PORT" \
    | head -n 1 \
    | tr -d '\r'
)
record http_status_line "${status_line:-missing}"

if [[ "$status_line" != HTTP/* ]]; then
  record preflight_status invalid_http_response
  stop_target
  exit 6
fi

stop_target
if nc -z "$PREFLIGHT_HOST" "$PREFLIGHT_PORT" >/dev/null 2>&1; then
  record preflight_status port_still_in_use_after_stop
  exit 7
fi

record preflight_completed_at "$(date --iso-8601=seconds)"
record preflight_status passed
