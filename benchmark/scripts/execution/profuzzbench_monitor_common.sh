#!/bin/bash

PROFUZZBENCH_MONITOR="${PROFUZZBENCH_MONITOR:-1}"
PROFUZZBENCH_MONITOR_INTERVAL="${PROFUZZBENCH_MONITOR_INTERVAL:-5}"
PROFUZZBENCH_MONITOR_DASHBOARD="${PROFUZZBENCH_MONITOR_DASHBOARD:-0}"
PROFUZZBENCH_INTERRUPT_ACTION="${PROFUZZBENCH_INTERRUPT_ACTION:-stop}"
PROFUZZBENCH_INTERRUPT_TIMEOUT="${PROFUZZBENCH_INTERRUPT_TIMEOUT:-10}"
PROFUZZBENCH_COLLECT_ON_INTERRUPT="${PROFUZZBENCH_COLLECT_ON_INTERRUPT:-1}"

profuzzbench_format_duration() {
  local seconds=${1:-0}
  local hours minutes

  if [ "$seconds" -lt 0 ]; then
    seconds=0
  fi

  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  seconds=$((seconds % 60))
  printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}

profuzzbench_container_runtime() {
  local status=$1
  local started_at=$2
  local finished_at=$3
  local now=$4
  local started_epoch finished_epoch

  started_epoch=$(date -d "$started_at" +%s 2>/dev/null || printf '0')
  if [ "$started_epoch" -le 0 ]; then
    printf '%s' "-"
    return
  fi

  if [ "$status" = "running" ] || [ "$finished_at" = "0001-01-01T00:00:00Z" ]; then
    finished_epoch=$now
  else
    finished_epoch=$(date -d "$finished_at" +%s 2>/dev/null || printf '%s' "$now")
  fi

  profuzzbench_format_duration "$((finished_epoch - started_epoch))"
}

profuzzbench_container_snapshot() {
  local id=$1
  docker inspect --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.StartedAt}}|{{.State.FinishedAt}}' "$id" 2>/dev/null
}

profuzzbench_container_note() {
  local status=$1
  local exit_code=$2
  local elapsed=$3
  local timeout=$4
  local note="OK"

  if [ "$status" = "unknown" ]; then
    note="UNKNOWN"
  elif [ "$status" != "running" ] && [ "$elapsed" -lt "$timeout" ]; then
    note="EARLY_EXIT"
  elif [ "$status" = "running" ] && [ "$elapsed" -gt "$timeout" ]; then
    note="OVERTIME"
  fi

  if [ "$exit_code" != "-" ] && [ "$exit_code" != "0" ]; then
    note="${note} EXIT_${exit_code}"
  fi

  printf '%s' "$note"
}

profuzzbench_print_container_rows() {
  local start_epoch=$1
  local timeout=$2
  shift 2
  local now elapsed index id snapshot status exit_code started_at finished_at runtime note
  local running=0
  local exited=0
  local abnormal=0

  now=$(date +%s)
  elapsed=$((now - start_epoch))
  index=1

  printf 'RUN   CONTAINER      STATUS       RUNTIME    EXIT   NOTE\n'
  for id in "$@"; do
    snapshot=$(profuzzbench_container_snapshot "$id")
    if [ -n "$snapshot" ]; then
      IFS='|' read -r status exit_code started_at finished_at <<< "$snapshot"
      runtime=$(profuzzbench_container_runtime "$status" "$started_at" "$finished_at" "$now")
    else
      status="unknown"
      exit_code="-"
      runtime="-"
    fi

    note=$(profuzzbench_container_note "$status" "$exit_code" "$elapsed" "$timeout")
    if [ "$status" = "running" ]; then
      running=$((running + 1))
    elif [ "$status" = "exited" ]; then
      exited=$((exited + 1))
    fi
    if [ "$note" != "OK" ] && [ "$note" != "OVERTIME" ]; then
      abnormal=$((abnormal + 1))
    fi

    printf '%-5s %-14s %-12s %-10s %-6s %s\n' "$index" "$id" "$status" "$runtime" "$exit_code" "$note"
    index=$((index + 1))
  done

  PROFUZZBENCH_MONITOR_RUNNING=$running
  PROFUZZBENCH_MONITOR_EXITED=$exited
  PROFUZZBENCH_MONITOR_ABNORMAL=$abnormal
}

profuzzbench_render_monitor() {
  local label=$1
  local timeout=$2
  local start_epoch=$3
  shift 3
  local now elapsed remaining timeout_text elapsed_text remaining_text

  now=$(date +%s)
  elapsed=$((now - start_epoch))
  remaining=$((timeout - elapsed))
  timeout_text=$(profuzzbench_format_duration "$timeout")
  elapsed_text=$(profuzzbench_format_duration "$elapsed")
  remaining_text=$(profuzzbench_format_duration "$remaining")

  if [ -t 1 ] && [ "$PROFUZZBENCH_MONITOR_DASHBOARD" = "1" ]; then
    printf '\033[H\033[J'
  fi

  printf 'ProFuzzBench monitor | %s\n' "$label"
  printf 'elapsed=%s timeout=%s remaining=%s\n\n' "$elapsed_text" "$timeout_text" "$remaining_text"
  profuzzbench_print_container_rows "$start_epoch" "$timeout" "$@"
  printf '\ncontainers: running=%s exited=%s abnormal=%s\n' \
    "$PROFUZZBENCH_MONITOR_RUNNING" \
    "$PROFUZZBENCH_MONITOR_EXITED" \
    "$PROFUZZBENCH_MONITOR_ABNORMAL"
}

profuzzbench_monitor_containers() {
  local label=$1
  local timeout=$2
  shift 2
  local start_epoch

  if [ "$PROFUZZBENCH_MONITOR" = "0" ]; then
    return 0
  fi

  start_epoch=${PROFUZZBENCH_RUN_START_EPOCH:-$(date +%s)}
  while true; do
    profuzzbench_render_monitor "$label" "$timeout" "$start_epoch" "$@"
    sleep "$PROFUZZBENCH_MONITOR_INTERVAL"
  done
}

profuzzbench_print_final_container_summary() {
  local label=$1
  local timeout=$2
  shift 2
  local start_epoch

  start_epoch=${PROFUZZBENCH_RUN_START_EPOCH:-$(($(date +%s) - timeout))}
  printf '\nProFuzzBench final container summary | %s\n' "$label"
  profuzzbench_print_container_rows "$start_epoch" "$timeout" "$@"
}

profuzzbench_stop_monitor() {
  local monitor_pid=${1:-}

  if [ -n "$monitor_pid" ]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
}

profuzzbench_interrupt_containers() {
  local action=$PROFUZZBENCH_INTERRUPT_ACTION

  if [ "$#" -eq 0 ]; then
    printf 'ProFuzzBench interrupt: no containers have been started yet.\n'
    return 0
  fi

  case "$action" in
    stop)
      printf 'ProFuzzBench interrupt: stopping containers with timeout=%ss: %s\n' \
        "$PROFUZZBENCH_INTERRUPT_TIMEOUT" "$*"
      docker stop -t "$PROFUZZBENCH_INTERRUPT_TIMEOUT" "$@" >/dev/null 2>&1 || true
      ;;
    kill)
      printf 'ProFuzzBench interrupt: killing containers: %s\n' "$*"
      docker kill "$@" >/dev/null 2>&1 || true
      ;;
    leave)
      printf 'ProFuzzBench interrupt: leaving containers running: %s\n' "$*"
      printf 'Use docker logs <container_id> or docker stop <container_id> manually.\n'
      ;;
    *)
      printf 'ProFuzzBench interrupt: unknown PROFUZZBENCH_INTERRUPT_ACTION=%s; leaving containers running: %s\n' \
        "$action" "$*"
      ;;
  esac
}
