#!/bin/bash

PROFUZZBENCH_MONITOR="${PROFUZZBENCH_MONITOR:-1}"
PROFUZZBENCH_MONITOR_INTERVAL="${PROFUZZBENCH_MONITOR_INTERVAL:-5}"
PROFUZZBENCH_MONITOR_PROJECT_INTERVAL="${PROFUZZBENCH_MONITOR_PROJECT_INTERVAL:-5}"
PROFUZZBENCH_MONITOR_DASHBOARD="${PROFUZZBENCH_MONITOR_DASHBOARD:-0}"
PROFUZZBENCH_INTERRUPT_ACTION="${PROFUZZBENCH_INTERRUPT_ACTION:-stop}"
PROFUZZBENCH_INTERRUPT_TIMEOUT="${PROFUZZBENCH_INTERRUPT_TIMEOUT:-10}"
PROFUZZBENCH_COLLECT_ON_INTERRUPT="${PROFUZZBENCH_COLLECT_ON_INTERRUPT:-1}"
PROFUZZBENCH_MONITOR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profuzzbench_monitor.py"

profuzzbench_monitor_containers() {
  local label=$1
  local timeout=$2
  shift 2
  local start_epoch
  local screen_option=()
  local stage_option=()
  local progress_option=()
  local docker_label_option=()

  if [ "$PROFUZZBENCH_MONITOR" = "0" ]; then
    return 0
  fi

  start_epoch=${PROFUZZBENCH_RUN_START_EPOCH:-$(date +%s)}
  if [ "$PROFUZZBENCH_MONITOR_DASHBOARD" = "1" ]; then
    screen_option=(--screen)
  fi
  if [ -n "${PROFUZZBENCH_MONITOR_STAGE_FILE:-}" ]; then
    stage_option=(--stage-file "$PROFUZZBENCH_MONITOR_STAGE_FILE")
  fi
  if [ -n "${PROFUZZBENCH_MONITOR_PROGRESS_FILE:-}" ]; then
    progress_option=(--progress-file "$PROFUZZBENCH_MONITOR_PROGRESS_FILE")
  fi
  if [ -n "${PROFUZZBENCH_MONITOR_DOCKER_LABEL:-}" ]; then
    docker_label_option=(
      --docker-label "$PROFUZZBENCH_MONITOR_DOCKER_LABEL"
    )
  fi

  # Callers run this function in the background.  Replacing that subshell
  # makes $! the Python/Rich process, so SIGTERM closes Live cleanly instead
  # of leaving an orphaned dashboard behind.
  exec python3 "$PROFUZZBENCH_MONITOR_SCRIPT" monitor \
    --label "$label" \
    --timeout "$timeout" \
    --start-epoch "$start_epoch" \
    --interval "$PROFUZZBENCH_MONITOR_INTERVAL" \
    --project-interval "$PROFUZZBENCH_MONITOR_PROJECT_INTERVAL" \
    "${screen_option[@]}" \
    "${stage_option[@]}" \
    "${progress_option[@]}" \
    "${docker_label_option[@]}" \
    "$@"
}

profuzzbench_print_final_container_summary() {
  local label=$1
  local timeout=$2
  shift 2
  local start_epoch
  local stage_option=()
  local progress_option=()
  local docker_label_option=()

  start_epoch=${PROFUZZBENCH_RUN_START_EPOCH:-$(($(date +%s) - timeout))}
  if [ -n "${PROFUZZBENCH_MONITOR_STAGE_FILE:-}" ]; then
    stage_option=(--stage-file "$PROFUZZBENCH_MONITOR_STAGE_FILE")
  fi
  if [ -n "${PROFUZZBENCH_MONITOR_PROGRESS_FILE:-}" ]; then
    progress_option=(--progress-file "$PROFUZZBENCH_MONITOR_PROGRESS_FILE")
  fi
  if [ -n "${PROFUZZBENCH_MONITOR_DOCKER_LABEL:-}" ]; then
    docker_label_option=(
      --docker-label "$PROFUZZBENCH_MONITOR_DOCKER_LABEL"
    )
  fi
  python3 "$PROFUZZBENCH_MONITOR_SCRIPT" snapshot \
    --label "$label" \
    --timeout "$timeout" \
    --start-epoch "$start_epoch" \
    "${stage_option[@]}" \
    "${progress_option[@]}" \
    "${docker_label_option[@]}" \
    "$@"
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
