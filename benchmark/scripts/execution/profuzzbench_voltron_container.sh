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
RUN_COMPLIANCE_ANALYSIS=${VOLTRON_RUN_COMPLIANCE_ANALYSIS:-0}
VOLTRON_RUN_MODE=${VOLTRON_RUN_MODE:-full}
VOLTRON_MODEL_BATCH=${VOLTRON_MODEL_BATCH:-}
VOLTRON_LEARNING_BUNDLE_PATH=${VOLTRON_LEARNING_BUNDLE_PATH:-}
TIMEOUT_MINUTES=$(( (TIMEOUT_SECONDS + 59) / 60 ))

case "$RUN_COMPLIANCE_ANALYSIS" in
  0|1) ;;
  *)
    printf 'VOLTRON: VOLTRON_RUN_COMPLIANCE_ANALYSIS must be 0 or 1\n' >&2
    exit 2
    ;;
esac

case "$VOLTRON_RUN_MODE" in
  full|learn-export) ;;
  *)
    printf 'VOLTRON: VOLTRON_RUN_MODE must be full or learn-export\n' >&2
    exit 2
    ;;
esac

if [ -n "$VOLTRON_MODEL_BATCH" ]; then
  if [ "$VOLTRON_RUN_MODE" != full ]; then
    printf 'VOLTRON: VOLTRON_MODEL_BATCH requires VOLTRON_RUN_MODE=full\n' >&2
    exit 2
  fi
  case "$VOLTRON_MODEL_BATCH" in
    *[!A-Za-z0-9._-]*|'')
      printf 'VOLTRON: VOLTRON_MODEL_BATCH must be a safe batch name\n' >&2
      exit 2
      ;;
  esac
  if [ ! -r "$VOLTRON_LEARNING_BUNDLE_PATH" ]; then
    printf 'VOLTRON: model batch bundle is not readable: %s\n' \
      "$VOLTRON_LEARNING_BUNDLE_PATH" >&2
    exit 2
  fi
fi

case "$TARGET" in
  pure-ftpd) VOLTRON_TARGET=pureftpd ;;
  lighttpd1) VOLTRON_TARGET=lighttpd ;;
  *) VOLTRON_TARGET=$TARGET ;;
esac

rm -rf "$VOLTRON_DIR"
mkdir -p "$VOLTRON_DIR"
cp -a "$VOLTRON_SOURCE/." "$VOLTRON_DIR/"
cd "$VOLTRON_DIR"

VOLTRON_SOURCE_COMMIT=$(cat "$VOLTRON_SOURCE/.benchmark-voltron-commit" 2>/dev/null || printf 'unknown')
VOLTRON_LIFECYCLE_MODE=unsupported

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

voltron_lifecycle_preflight() {
  local executor=voltron/executor/executor.py
  local config=config/configs.yaml

  if ! grep -Fq 'def initialize_environment' "$executor" \
    || ! grep -Fq 'def run_subject_readiness' "$executor" \
    || ! grep -Fq 'readiness_script' voltron/configs.py; then
    printf 'VOLTRON: INCOMPATIBLE_VOLTRON_SNAPSHOT; lifecycle readiness support is missing\n' >&2
    return 1
  fi

  case "$VOLTRON_TARGET" in
    forked-daapd)
      if ! grep -Fq 'readiness_script: ready.sh' "$config" \
        || [ ! -x "config/subjects/forked-daapd/ready.sh" ]; then
        printf 'VOLTRON: forked-daapd readiness configuration is missing\n' >&2
        return 1
      fi
      VOLTRON_LIFECYCLE_MODE=environment_once+daap_readiness
      ;;
    proftpd)
      if ! grep -Fq 'readiness_adapter: ftp_banner_active_socket' "$config"; then
        printf 'VOLTRON: ProFTPD readiness adapter is missing\n' >&2
        return 1
      fi
      VOLTRON_LIFECYCLE_MODE=environment_once+ftp_banner_readiness
      ;;
    *)
      VOLTRON_LIFECYCLE_MODE=environment_once+socket_readiness
      ;;
  esac
}

if ! voltron_lifecycle_preflight; then
  exit 2
fi

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

  # The hardened Voltron snapshot owns lifecycle scripts for these targets.
  # Do not overwrite them with an older bench fallback once the capability
  # preflight has passed.
  if [[ "$TARGET" == forked-daapd || "$TARGET" == proftpd ]]; then
    printf 'VOLTRON: using snapshot lifecycle scripts for %s\n' "$TARGET"
    return 0
  fi

  for source_file in "$source_dir"/*.sh; do
    [ -e "$source_file" ] || continue
    install -m 0755 "$source_file" "$destination_dir/${source_file##*/}"
  done
}

apply_subject_overrides

apply_forked_daapd_timeout_overrides() {
  local config=config/configs.yaml
  local setup_timeout=${VOLTRON_FORKED_DAAPD_SETUP_TIMEOUT_SECONDS:-}
  # The historical five-second HTTP probe limit was reached under normal
  # concurrent load.  Keep a target-scoped ten-second default while allowing
  # an experiment to override it explicitly.
  local readiness_timeout=${VOLTRON_FORKED_DAAPD_READINESS_TIMEOUT_SECONDS:-10}

  [ "$TARGET" = forked-daapd ] || return 0
  python3 - "$config" "$setup_timeout" "$readiness_timeout" <<'PYTHON'
import re
import sys
path, setup_value, readiness_value = sys.argv[1:]
def valid(value, name):
    if not value:
        return None
    try:
        parsed = float(value)
    except ValueError as error:
        raise SystemExit(f"VOLTRON: {name} must be a positive number") from error
    if parsed <= 0:
        raise SystemExit(f"VOLTRON: {name} must be a positive number")
    return value
setup_value = valid(setup_value, "VOLTRON_FORKED_DAAPD_SETUP_TIMEOUT_SECONDS")
readiness_value = valid(readiness_value, "VOLTRON_FORKED_DAAPD_READINESS_TIMEOUT_SECONDS")
text = open(path, encoding="utf-8").read()
match = re.search(r"^forked-daapd:\n(?P<body>(?:^[ ]{2}.*\n)*)", text, re.M)
if match is None:
    raise SystemExit("VOLTRON: forked-daapd target configuration is missing")
body = match.group("body")
for key, value in (("setup_timeout_seconds", setup_value), ("readiness_timeout_seconds", readiness_value)):
    if value is None:
        continue
    line = f"  {key}: {value}\n"
    if re.search(rf"^  {re.escape(key)}:.*\n", body, re.M):
        body = re.sub(rf"^  {re.escape(key)}:.*\n", line, body, flags=re.M)
    else:
        body += line
text = text[:match.start("body")] + body + text[match.end("body"):]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PYTHON
  printf 'VOLTRON: forked-daapd timeouts: socket=%ss http=%ss\n' \
    "${setup_timeout:-default}" "${readiness_timeout:-default}"
}

apply_forked_daapd_timeout_overrides

apply_exim_lifecycle_override() {
  local config=config/configs.yaml

  [ "$TARGET" = exim ] || return 0

  python3 - "$config" <<'PYTHON'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
match = re.search(r"^exim:\n(?P<body>(?:^[ ]{2}.*\n)*)", text, re.M)
if match is None:
    raise SystemExit("VOLTRON: Exim target configuration is missing")

body = match.group("body")
line = "  readiness_script: ready.sh\n"
if re.search(r"^  readiness_script:.*\n", body, re.M):
    body = re.sub(r"^  readiness_script:.*\n", line, body, flags=re.M)
else:
    body += line

text = text[:match.start("body")] + body + text[match.end("body"):]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PYTHON
  printf 'VOLTRON: Exim uses controlled PID lifecycle and SMTP banner readiness\n'
}

apply_exim_lifecycle_override

verify_subject_lifecycle_override() {
  if [[ "$TARGET" == bftpd ]] \
    && ! grep -Fq 'exec /home/ubuntu/experiments/bftpd/bftpd' \
      config/subjects/bftpd/run.sh; then
    printf 'VOLTRON: Bftpd lifecycle override did not take ownership of the SUT process\n' >&2
    return 1
  fi

  if [[ "$TARGET" == exim ]] \
    && { ! grep -Fq 'exec /usr/exim/bin/exim' config/subjects/exim/run.sh \
      || ! grep -Fq 'readiness_script: ready.sh' config/configs.yaml \
      || [ ! -x config/subjects/exim/ready.sh ]; }; then
    printf 'VOLTRON: Exim lifecycle override did not take ownership of the SUT process\n' >&2
    return 1
  fi
}

verify_subject_lifecycle_override

main_runtime_patch_is_present() {
  local synthesizer=voltron/synthesizer/synthesizer.py

  # The original main snapshot used these explicit terminal messages.  Keep
  # this branch for older Voltron revisions to which the runtime patch applies.
  if grep -Fq 'giving up mutator generation for %s after %d attempts' \
    "$synthesizer" \
    && grep -Fq 'giving up checker generation for %s after %d attempts' \
      "$synthesizer" \
    && grep -Fq 'giving up observer generation for %s after %d attempts' \
      "$synthesizer"; then
    return 0
  fi

  # Voltron main after PR #19 retains bounded retries but deliberately changes
  # mutator/observer failures into validated fallbacks.  Its log text differs
  # from the older patch, so recognize the capabilities instead of attempting
  # to apply an obsolete multi-hunk patch to an already hardened source tree.
  grep -Fq 'generation_retry_limit' "$synthesizer" \
    && grep -Fq "'Producer: falling back to the best generator for %s after %d attempts'" \
      "$synthesizer" \
    && grep -Fq 'RAW_SHA256_OBSERVER' "$synthesizer" \
    && grep -Fq 'using raw SHA-256 observer fallback for %s' "$synthesizer" \
    && grep -Fq 'giving up checker generation for %s after %d attempts' \
      "$synthesizer"
}

apply_main_runtime_patch() {
  local patch_file=/opt/voltron-main-runtime.patch

  [ -r "$patch_file" ] || return 0
  if main_runtime_patch_is_present; then
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

apply_forked_daapd_readiness_runtime_patch() {
  local patch_file=/opt/voltron-executor-readiness-runtime.patch

  [ "$TARGET" = forked-daapd ] || return 0
  [ -r "$patch_file" ] || return 0
  if grep -Fq 'self.setup_time_s, self.setup_timeout_s, 100 * self.setup_time_s' \
    voltron/executor/executor.py; then
    printf 'VOLTRON: forked-daapd socket readiness runtime patch is already present\n'
    return 0
  fi
  if ! patch --batch --forward -p1 < "$patch_file"; then
    printf 'VOLTRON: forked-daapd socket readiness runtime patch did not apply\n' >&2
    return 1
  fi
}

apply_forked_daapd_readiness_runtime_patch

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

if [ "${UV_OFFLINE:-0}" = 1 ]; then
  unwritable_cache_path=$(find "${UV_CACHE_DIR:-/home/ubuntu/.cache/uv}" -xdev \
    \( -type d ! -writable -o -type f ! -writable \) \
    -print -quit 2>/dev/null || true)
  if [ -n "$unwritable_cache_path" ]; then
    printf 'VOLTRON_RUNTIME_PREFLIGHT_FAILED: offline uv cache is not writable: %s\n' \
      "$unwritable_cache_path" >&2
    exit 2
  fi
  if ! uv sync --locked --offline; then
    printf 'VOLTRON_RUNTIME_PREFLIGHT_FAILED: offline uv cache is incomplete\n' >&2
    exit 2
  fi
else
  uv sync --locked
fi

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
  local imported_bundle="$component_root/imported_learning_bundle.tar.gz"
  local exported_bundle_sha256=
  local status=0

  set_stage "FINALIZING 0/4: exporting synthesized components"
  mkdir -p "$component_root/equipment" "$component_root/models"
  printf 'target=%s\n' "$VOLTRON_TARGET" > "$manifest"
  printf 'source_root=%s\n' "$VOLTRON_DIR" >> "$manifest"

  if [ -n "$VOLTRON_MODEL_BATCH" ]; then
    # Imported batches deliberately keep their equipment beside the model,
    # rather than in component/equipment/<target>.  Export that exact
    # provenance boundary instead of reporting a false partial export.
    equipment_source="component/models/$VOLTRON_TARGET/$VOLTRON_MODEL_BATCH/equipment"
    models_source="component/models/$VOLTRON_TARGET/$VOLTRON_MODEL_BATCH"
    printf 'model_batch=%s\n' "$VOLTRON_MODEL_BATCH" >> "$manifest"
  fi

  if [ -d "$equipment_source" ]; then
    cp -a "$equipment_source" "$component_root/equipment/$VOLTRON_TARGET"
    printf 'equipment=exported\n' >> "$manifest"
  else
    printf 'equipment=missing\n' >> "$manifest"
    status=1
  fi

  if [ -d "$models_source" ]; then
    if [ -n "$VOLTRON_MODEL_BATCH" ]; then
      mkdir -p "$component_root/models/$VOLTRON_TARGET"
      cp -a "$models_source" \
        "$component_root/models/$VOLTRON_TARGET/$VOLTRON_MODEL_BATCH"
    else
      cp -a "$models_source" "$component_root/models/"
    fi
    printf 'models=exported\n' >> "$manifest"
  else
    printf 'models=missing\n' >> "$manifest"
    status=1
  fi

  IMPORTED_BUNDLE_ARCHIVE_STATUS=NOT_REQUESTED
  if [ -n "$VOLTRON_MODEL_BATCH" ]; then
    if cp -a "$VOLTRON_LEARNING_BUNDLE_PATH" "$imported_bundle"; then
      exported_bundle_sha256=$(sha256sum "$imported_bundle" | awk '{print $1}')
      if [ "$exported_bundle_sha256" = "$MODEL_IMPORT_BUNDLE_SHA256" ]; then
        IMPORTED_BUNDLE_ARCHIVE_STATUS=COMPLETED
        printf 'imported_bundle=exported\n' >> "$manifest"
        printf 'imported_bundle_sha256=%s\n' "$exported_bundle_sha256" >> "$manifest"
      else
        IMPORTED_BUNDLE_ARCHIVE_STATUS=SHA256_MISMATCH
        printf 'imported_bundle=sha256_mismatch\n' >> "$manifest"
        status=1
      fi
    else
      IMPORTED_BUNDLE_ARCHIVE_STATUS=FAILED
      printf 'imported_bundle=missing\n' >> "$manifest"
      status=1
    fi
  fi

  printf 'export_status=%s\n' "$status" >> "$manifest"
  return "$status"
}

run_compliance_analysis() {
  if [ "$RUN_COMPLIANCE_ANALYSIS" != "1" ]; then
    PAIR_COUNT=0
    COMPLIANCE_STATE=SKIPPED
    set_stage "FINALIZING 1/4: compliance analysis skipped"
    printf 'Skipping compliance analysis (set VOLTRON_RUN_COMPLIANCE_ANALYSIS=1 to enable)\n'
    return 0
  fi

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
    "$COMPONENT_EXPORT_STATUS" \
    "$VOLTRON_RUN_MODE" \
    "$LEARNING_EXPORT_STATUS" \
    "$LEARNING_BUNDLE_SHA256" \
    "$MODEL_IMPORT_STATUS" \
    "$MODEL_IMPORT_BUNDLE_SHA256" \
    "$VOLTRON_MODEL_BATCH" \
    "$IMPORTED_BUNDLE_ARCHIVE_STATUS" \
    "$VOLTRON_SOURCE_COMMIT" \
    "$VOLTRON_LIFECYCLE_MODE" <<'PY'
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
    run_mode,
    learning_export_status,
    learning_bundle_sha256,
    model_import_status,
    model_import_bundle_sha256,
    model_batch,
    imported_bundle_archive_status,
    voltron_source_commit,
    lifecycle_mode,
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
    "voltron_run_mode": run_mode,
    "learning_export_status": learning_export_status,
    "learning_bundle_sha256": learning_bundle_sha256,
    "model_import_status": model_import_status,
    "model_import_bundle_sha256": model_import_bundle_sha256,
    "model_batch": model_batch or None,
    "imported_bundle_archive_status": imported_bundle_archive_status,
    "voltron_source_commit": voltron_source_commit,
    "lifecycle_mode": lifecycle_mode,
}

target = Path(output_path)
temporary = target.with_suffix(target.suffix + ".tmp")
temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
temporary.replace(target)
PY
}

export_learning_bundle() {
  local bundle="$OUTDIR/learning_bundle.tar.gz"
  local report="$OUTDIR/learning_export_status.json"

  set_stage "FINALIZING 1/4: validating learning bundle"
  LEARNING_EXPORT_STATUS=$(python3 - "$bundle" "$report" "$VOLTRON_TARGET" <<'PY'
import hashlib
import json
import sys
import tarfile
from pathlib import Path

bundle, report_path, target = map(Path, sys.argv[1:])
payload = {"target": target.name, "bundle": str(bundle), "status": "FAILED"}
try:
    digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
    with tarfile.open(bundle, "r:gz") as archive:
        member = archive.getmember("manifest.json")
        manifest = json.loads(archive.extractfile(member).read().decode("utf-8"))
    if manifest.get("target") != target.name:
        raise ValueError("bundle target mismatch")
    if not isinstance(manifest.get("files"), dict) or not manifest["files"]:
        raise ValueError("bundle manifest has no files")
    has_model = any(name.endswith("evolved_hypothesis.pkl") for name in manifest["files"])
    has_partial = any(name.endswith("partial_guidance.pkl") for name in manifest["files"])
    if not (has_model or has_partial):
        raise ValueError("bundle has neither complete model nor partial guidance")
    payload.update({
        "status": "COMPLETED",
        "sha256": digest,
        "bundle_format": manifest.get("format"),
        "protocol": manifest.get("protocol"),
        "complete_model": has_model,
        "partial_guidance": has_partial,
        "file_count": len(manifest["files"]),
    })
except Exception as exc:
    payload["error"] = str(exc)
report_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(payload.get("status", "FAILED"))
print(payload.get("sha256", ""), file=sys.stderr)
PY
)
  LEARNING_BUNDLE_SHA256=$(python3 - "$report" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("sha256", ""))
except Exception:
    print("")
PY
)
  [ "$LEARNING_EXPORT_STATUS" = COMPLETED ]
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

STATUS=255
COMPONENT_EXPORT_STATUS=255
LEARNING_EXPORT_STATUS=NOT_REQUESTED
LEARNING_BUNDLE_SHA256=
MODEL_IMPORT_STATUS=NOT_REQUESTED
MODEL_IMPORT_BUNDLE_SHA256=
IMPORTED_BUNDLE_ARCHIVE_STATUS=NOT_REQUESTED

import_model_batch() {
  local report="$OUTDIR/model_import.json"

  [ -n "$VOLTRON_MODEL_BATCH" ] || return 0
  set_stage "IMPORTING 0/4: activating model batch $VOLTRON_MODEL_BATCH"
  MODEL_IMPORT_BUNDLE_SHA256=$(sha256sum "$VOLTRON_LEARNING_BUNDLE_PATH" | awk '{print $1}')
  if uv run cli.py \
      --sut "$VOLTRON_TARGET" \
      --import-learning-bundle "$VOLTRON_LEARNING_BUNDLE_PATH" \
      --activate-import --batch-id "$VOLTRON_MODEL_BATCH" >"$report" 2>&1; then
    MODEL_IMPORT_STATUS=COMPLETED
    return 0
  fi
  MODEL_IMPORT_STATUS=FAILED
  printf 'VOLTRON: failed to import model batch %s; see %s\n' \
    "$VOLTRON_MODEL_BATCH" "$report" >&2
  return 1
}

if ! import_model_batch; then
  exit 2
fi

if [ "$VOLTRON_RUN_MODE" = learn-export ]; then
  set_stage "LEARNING 0/4: model learning"
  mode_args=(--learn-and-export)
else
  if [ -n "$VOLTRON_MODEL_BATCH" ]; then
    set_stage "FUZZING 0/4: imported model batch $VOLTRON_MODEL_BATCH"
    mode_args=(--model-batch "$VOLTRON_MODEL_BATCH")
  else
    set_stage "FUZZING 0/4"
    mode_args=()
  fi
fi
uv run cli.py \
  --sut "$VOLTRON_TARGET" \
  --algorithm state \
  --time "$TIMEOUT_MINUTES" \
  --output "$OUTDIR" "${mode_args[@]}" &
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

if [ "$VOLTRON_RUN_MODE" = learn-export ]; then
  if ! export_learning_bundle; then
    LEARNING_EXPORT_STATUS=FAILED
  fi
  PAIR_COUNT=0
  COMPLIANCE_STATE=SKIPPED_LEARNING_ONLY
  COMPLIANCE_STATUS=0
  COVERAGE_STATE=SKIPPED_LEARNING_ONLY
  COVERAGE_STATUS=0
else
  LEARNING_EXPORT_STATUS=NOT_REQUESTED
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
if [ "$LEARNING_EXPORT_STATUS" = FAILED ]; then
  exit 1
fi
exit "$COVERAGE_STATUS"
