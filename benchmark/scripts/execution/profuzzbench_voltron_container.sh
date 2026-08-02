#!/bin/bash

set -u

TARGET=$1
OUTDIR=$2
TIMEOUT_SECONDS=$3
SKIPCOUNT=${4:-1}

VOLTRON_SOURCE=${VOLTRON_SOURCE:-/opt/voltron-src}
VOLTRON_DIR=${VOLTRON_DIR:-/home/ubuntu/voltron-runtime}
STATS_INTERVAL=${VOLTRON_STATS_INTERVAL:-10}
COMPLIANCE_ANALYZER=${VOLTRON_COMPLIANCE_ANALYZER:-analyze_compliance.py}
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

for required_file in \
  pyproject.toml \
  cli.py \
  config/configs.yaml \
  voltron/synthesizer/synthesizer.py; do
  if [ ! -f "$required_file" ]; then
    printf 'VOLTRON: prepared source is incomplete; missing %s\n' \
      "$required_file" >&2
    exit 2
  fi
done

apply_subject_overrides() {
  local source_dir="/opt/voltron-subject-overrides/${TARGET}"
  local destination_dir="config/subjects/${VOLTRON_TARGET}"
  local source_file

  [ -d "$source_dir" ] || return 0
  [ -d "$destination_dir" ] || {
    printf 'VOLTRON: missing subject directory for override: %s\n' \
      "$destination_dir" >&2
    return 1
  }

  for source_file in "$source_dir"/*.sh; do
    [ -e "$source_file" ] || continue
    install -m 0755 "$source_file" "$destination_dir/${source_file##*/}"
  done
}

apply_subject_overrides

apply_main_runtime_patch() {
  local patch_file=/opt/voltron-main-runtime.patch

  [ -r "$patch_file" ] || return 0
  if grep -Fq 'giving up mutator generation for %s after %d attempts' \
    voltron/synthesizer/synthesizer.py \
    && grep -Fq 'giving up checker generation for %s after %d attempts' \
      voltron/synthesizer/synthesizer.py \
    && grep -Fq 'giving up observer generation for %s after %d attempts' \
      voltron/synthesizer/synthesizer.py; then
    printf 'VOLTRON: main-snapshot runtime patch is already present\n'
    return 0
  fi
  if ! patch --batch --forward -p1 < "$patch_file"; then
    printf 'VOLTRON: main-snapshot runtime patch did not apply\n' >&2
    return 1
  fi
}

apply_main_runtime_patch

apply_udp_bind_runtime_patch() {
  local patch_file=/opt/voltron-udp-bind-runtime.patch

  [ -r "$patch_file" ] || return 0
  if grep -Fq 'self.local_port = (' voltron/executor/executor.py \
    && grep -Fq 'sock.bind((self.host, self.local_port))' \
      voltron/executor/executor.py; then
    printf 'VOLTRON: UDP bind runtime patch is already present\n'
    return 0
  fi
  if ! patch --batch --forward -p1 < "$patch_file"; then
    printf 'VOLTRON: UDP bind runtime patch did not apply\n' >&2
    return 1
  fi
}

apply_udp_bind_runtime_patch

apply_generator_evolution_runtime_patch() {
  local patch_file=/opt/voltron-generator-evolution-runtime.patch

  [ -r "$patch_file" ] || return 0
  if grep -Fq 'giving up generator evolution for %s after %d attempts' \
    voltron/synthesizer/synthesizer.py; then
    printf 'VOLTRON: generator-evolution runtime patch is already present\n'
    return 0
  fi
  if ! patch --batch --forward -p1 < "$patch_file"; then
    printf 'VOLTRON: generator-evolution runtime patch did not apply\n' >&2
    return 1
  fi
}

apply_generator_evolution_runtime_patch

replace_llm_setting() {
  local field=$1
  local value=$2
  local yaml_value

  yaml_value=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$value")
  yaml_value=${yaml_value//\\/\\\\}
  yaml_value=${yaml_value//&/\\&}
  yaml_value=${yaml_value//|/\\|}
  sed -i "s|^  ${field}:.*|  ${field}: ${yaml_value}|" config/configs.yaml
}

replace_llm_setting base_url "$VOLTRON_LLM_BASE_URL"
replace_llm_setting api_key "$VOLTRON_LLM_API_KEY"
replace_llm_setting model "$VOLTRON_LLM_MODEL"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

uv sync --locked

PLOT_DATA="$OUTDIR/plot_data"
STAGE_FILE="$OUTDIR/.profuzzbench-stage"
cat > "$PLOT_DATA" <<'EOF'
# unix_time, cycles_done, cur_path, paths_total, pending_total, pending_favs, map_size, unique_crashes, unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges, chat_times
EOF

set_stage() {
  printf '%s\n' "$1" > "$STAGE_FILE"
}

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

export_synthesized_component() {
  local component_root="$OUTDIR/synthesized_component"
  local equipment_source="component/equipment/$VOLTRON_TARGET"
  local models_source="component/models/$VOLTRON_TARGET"
  local manifest="$component_root/export_manifest.txt"
  local status=0

  set_stage "FINALIZING 0/4: exporting synthesized components"
  mkdir -p "$component_root/equipment" "$component_root/models"
  printf 'target=%s\n' "$VOLTRON_TARGET" > "$manifest"
  printf 'source_root=%s\n' "$VOLTRON_DIR" >> "$manifest"

  if [ -d "$equipment_source" ]; then
    cp -a "$equipment_source" "$component_root/equipment/"
    printf 'equipment=exported\n' >> "$manifest"
  else
    printf 'equipment=missing\n' >> "$manifest"
    status=1
  fi

  if [ -d "$models_source" ]; then
    cp -a "$models_source" "$component_root/models/"
    printf 'models=exported\n' >> "$manifest"
  else
    printf 'models=missing\n' >> "$manifest"
    status=1
  fi

  printf 'export_status=%s\n' "$status" >> "$manifest"
  return "$status"
}

run_compliance_analysis() {
  local log_file="$OUTDIR/analyze_compliance.log"
  local pair_files=()

  set_stage "FINALIZING 1/4: compliance analysis"
  printf 'Running compliance analysis for %s with %s\n' \
    "$VOLTRON_TARGET" "$COMPLIANCE_ANALYZER" | tee "$log_file"

  shopt -s nullglob
  pair_files=(
    "$OUTDIR"/pair_*.json
    "$OUTDIR"/request_response_pairs/pair_*.json
  )
  PAIR_COUNT=${#pair_files[@]}
  if (( PAIR_COUNT == 0 )); then
    COMPLIANCE_STATE=NO_COMPLIANCE_INPUT
    # Pair recording is optional for a fuzz run.  Voltron can finish the
    # fuzzing and coverage stages while producing no eligible relation (for
    # example when every interaction is rejected or interrupted).  Do not
    # turn that lack of compliance input into a failed container: the
    # postprocess manifest records the missing evidence explicitly and the
    # fuzz/coverage exit statuses remain authoritative.
    printf 'NO_COMPLIANCE_INPUT: no pair_*.json files were produced (non-fatal)\n' \
      | tee -a "$log_file"
    return 0
  fi

  if [ -f "$COMPLIANCE_ANALYZER" ]; then
    uv run python "$COMPLIANCE_ANALYZER" \
      --sut "$VOLTRON_TARGET" \
      --input "$OUTDIR" \
      --output "$OUTDIR" >> "$log_file" 2>&1
  else
    uv run "$COMPLIANCE_ANALYZER" \
      --sut "$VOLTRON_TARGET" \
      --input "$OUTDIR" \
      --output "$OUTDIR" >> "$log_file" 2>&1
  fi
  local status=$?
  if [ "$status" -eq 0 ]; then
    COMPLIANCE_STATE=COMPLETED
  else
    COMPLIANCE_STATE=FAILED
  fi
  return "$status"
}

write_postprocess_status() {
  python3 - \
    "$OUTDIR/postprocess_status.json" \
    "$STATUS" \
    "$PAIR_COUNT" \
    "$COMPLIANCE_STATE" \
    "$COMPLIANCE_STATUS" \
    "$COVERAGE_STATE" \
    "$COVERAGE_STATUS" \
    "$COMPONENT_EXPORT_STATUS" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    voltron_status,
    pair_count,
    compliance_state,
    compliance_status,
    coverage_state,
    coverage_status,
    component_export_status,
) = sys.argv[1:]
payload = {
    "voltron_status": int(voltron_status),
    "pair_status": "AVAILABLE" if int(pair_count) > 0 else "EMPTY",
    "pair_count": int(pair_count),
    "compliance_status": compliance_state,
    "compliance_exit_code": int(compliance_status),
    "coverage_status": coverage_state,
    "coverage_exit_code": int(coverage_status),
    "component_export_status": "COMPLETED"
    if int(component_export_status) == 0 else "PARTIAL",
}
target = Path(output_path)
temporary = target.with_suffix(target.suffix + ".tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(target)
PY
}

run_code_coverage() {
  local result_dir

  set_stage "FINALIZING 2/4: coverage export"
  result_dir=$(realpath "$OUTDIR")
  printf 'Exporting Voltron test cases for AFLNet coverage replay\n'
  PYTHONPATH="$VOLTRON_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    uv run python /opt/voltron-export-aflnet-replay.py \
    --result-dir "$result_dir" || return
  /bin/bash /opt/voltron-coverage.sh \
    "$TARGET" "$result_dir" "$SKIPCOUNT"
}

set_stage "FUZZING 0/4"
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

COMPONENT_EXPORT_STATUS=0
export_synthesized_component || COMPONENT_EXPORT_STATUS=$?

PAIR_COUNT=0
COMPLIANCE_STATE=FAILED
run_compliance_analysis
COMPLIANCE_STATUS=$?

run_code_coverage
COVERAGE_STATUS=$?
if [ "$COVERAGE_STATUS" -eq 0 ]; then
  COVERAGE_STATE=COMPLETED
else
  COVERAGE_STATE=FAILED
fi

write_postprocess_status

set_stage "PACKAGING 3/4: creating archive"
tar -zcf "${OUTDIR}.tar.gz" "$OUTDIR"
set_stage "ARCHIVE READY 4/4"
if [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi
if [ "$COMPLIANCE_STATUS" -ne 0 ]; then
  exit "$COMPLIANCE_STATUS"
fi
exit "$COVERAGE_STATUS"
