#!/bin/bash

set -u

STATE_DIR=${KAMAILIO_PJSUA_STATE_DIR:-/tmp/kamailio-pjsua}
PID_FILE=${KAMAILIO_PJSUA_PID_FILE:-$STATE_DIR/pjsua.pid}
LOCK_FILE=${KAMAILIO_PJSUA_LOCK_FILE:-$STATE_DIR/pjsua.lock}
LOG_FILE=${KAMAILIO_PJSUA_LOG:-$STATE_DIR/lifecycle.log}
READY_TIMEOUT=${KAMAILIO_PJSUA_READY_TIMEOUT:-5}

mkdir -p "$STATE_DIR"

log_event() {
  printf '%s event=%s pid=%s port=5068 cli_port=34254 init=%s\n' \
    "$(date --iso-8601=seconds)" "$1" "${2:-}" \
    "${KAMAILIO_CONTAINER_INIT:-unknown}" >> "$LOG_FILE"
}

pid_is_pjsua() {
  local pid=$1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] \
    && [[ -r "/proc/$pid/comm" ]] \
    && [[ "$(<"/proc/$pid/comm")" == pjsua-* || "$(<"/proc/$pid/comm")" == pjsua ]] \
    && kill -0 "$pid" 2>/dev/null
}

stop_locked() {
  local pid=
  if [[ -s "$PID_FILE" ]]; then
    read -r pid < "$PID_FILE" || pid=
  fi
  if pid_is_pjsua "$pid"; then
    log_event term "$pid"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      log_event kill "$pid"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  elif [[ -n "$pid" ]]; then
    log_event stale-pid "$pid"
  fi
  rm -f "$PID_FILE"
}

port_ready() {
  local udp_ready=0
  local tcp_ready=0
  if command -v ss >/dev/null 2>&1; then
    ss -H -lun 2>/dev/null | awk '$4 ~ /:5068$/ { found=1 } END { exit(found ? 0 : 1) }' && udp_ready=1
    ss -H -ltn 2>/dev/null | awk '$4 ~ /:34254$/ { found=1 } END { exit(found ? 0 : 1) }' && tcp_ready=1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lun 2>/dev/null | awk '$4 ~ /:5068$/ { found=1 } END { exit(found ? 0 : 1) }' && udp_ready=1
    netstat -ltn 2>/dev/null | awk '$4 ~ /:34254$/ { found=1 } END { exit(found ? 0 : 1) }' && tcp_ready=1
  fi
  (( udp_ready == 1 && tcp_ready == 1 ))
}

start_locked() {
  stop_locked
  # Do not pass the lifecycle lock descriptor to pjsua.  Otherwise the
  # background child keeps the flock held after this wrapper returns and
  # blocks the next sequence's stop/status operation.
  "$@" 9>&- >/dev/null 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  log_event start "$pid"
  local deadline=$((SECONDS + READY_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log_event exited "$pid"
      rm -f "$PID_FILE"
      return 1
    fi
    if port_ready; then
      log_event ready "$pid"
      return 0
    fi
    sleep 0.1
  done
  log_event readiness-timeout "$pid"
  stop_locked
  return 1
}

command=${1:-start}
shift || true
exec 9>"$LOCK_FILE"
flock 9
case "$command" in
  start) start_locked "$@" ;;
  stop) stop_locked ;;
  status)
    pid=
    [[ -s "$PID_FILE" ]] && read -r pid < "$PID_FILE" || true
    if pid_is_pjsua "$pid"; then
      printf 'running pid=%s\n' "$pid"
    else
      printf 'stopped\n'
      exit 1
    fi
    ;;
  *) echo "usage: $0 {start|stop|status} [pjsua command...]" >&2; exit 2 ;;
esac
