#!/bin/bash

set -u

TARGET=$1
OUTDIR=$2
TIMEOUT_SECONDS=$3
SKIPCOUNT=${4:-1}

VOLTRON_SOURCE=${VOLTRON_SOURCE:-/opt/voltron-src}
VOLTRON_DIR=${VOLTRON_DIR:-/home/ubuntu/voltron-runtime}
STATS_INTERVAL=${VOLTRON_STATS_INTERVAL:-10}
TIMEOUT_MINUTES=$(( (TIMEOUT_SECONDS + 59) / 60 ))

case "$TARGET" in
  pure-ftpd) VOLTRON_TARGET=pureftpd ;;
  lighttpd1) VOLTRON_TARGET=lighttpd ;;
  *) VOLTRON_TARGET=$TARGET ;;
esac

rm -rf "$VOLTRON_DIR"
mkdir -p "$VOLTRON_DIR"
cp -a "$VOLTRON_SOURCE/." "$VOLTRON_DIR/"
cd "$VOLTRON_DIR"

if [ -n "${VOLTRON_LLM_BASE_URL:-}" ]; then
  sed -i "s|^  base_url:.*|  base_url: ${VOLTRON_LLM_BASE_URL}|" config/configs.yaml
fi
if [ -n "${VOLTRON_LLM_API_KEY:-}" ]; then
  sed -i "s|^  api_key:.*|  api_key: ${VOLTRON_LLM_API_KEY}|" config/configs.yaml
fi
if [ -n "${VOLTRON_LLM_MODEL:-}" ]; then
  sed -i "s|^  model:.*|  model: ${VOLTRON_LLM_MODEL}|" config/configs.yaml
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

uv sync --locked

PLOT_DATA="$OUTDIR/plot_data"
cat > "$PLOT_DATA" <<'EOF'
# unix_time, cycles_done, cur_path, paths_total, pending_total, pending_favs, map_size, unique_crashes, unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges, chat_times
EOF

record_status() {
  local status_file="$OUTDIR/fuzzer_status"
  local timestamp paths crashes nodes edges chat_tokens

  [ -f "$status_file" ] || return 0

  timestamp=$(date +%s)
  paths=$(awk -F: '/^exec_path_num/ {gsub(/[[:space:]]/, "", $2); print $2}' "$status_file")
  crashes=$(awk -F: '/^crash_num/ {gsub(/[[:space:]]/, "", $2); print $2}' "$status_file")
  nodes=$(awk -F: '/^distinct_resp/ {gsub(/[[:space:]]/, "", $2); print $2}' "$status_file")
  edges=$(awk -F: '/^resp_transitions/ {gsub(/[[:space:]]/, "", $2); print $2}' "$status_file")
  chat_tokens=$(awk -F: '/^chat_token/ {gsub(/[[:space:]]/, "", $2); print $2}' "$status_file")

  printf '%s, 0, 0, %s, 0, 0, 0, %s, 0, 0, 0, %s, %s, %s\n' \
    "$timestamp" "${paths:-0}" "${crashes:-0}" "${nodes:-0}" "${edges:-0}" \
    "${chat_tokens:-0}" >> "$PLOT_DATA"
}

uv run cli.py \
  --sut "$VOLTRON_TARGET" \
  --algorithm state \
  --time "$TIMEOUT_MINUTES" \
  --output "$OUTDIR" &
FUZZ_PID=$!

sample_count=0
while kill -0 "$FUZZ_PID" 2>/dev/null; do
  if (( sample_count % SKIPCOUNT == 0 )); then
    record_status
  fi
  sample_count=$((sample_count + 1))
  sleep "$STATS_INTERVAL"
done

wait "$FUZZ_PID"
STATUS=$?
record_status

# Voltron's replay-based code coverage is still experimental. Keep the
# ProFuzzBench file contract without inventing coverage measurements.
if [ ! -f "$OUTDIR/cov_over_time.csv" ]; then
  echo "Time,l_per,l_abs,b_per,b_abs" > "$OUTDIR/cov_over_time.csv"
fi

tar -zcf "${OUTDIR}.tar.gz" "$OUTDIR"
exit "$STATUS"
