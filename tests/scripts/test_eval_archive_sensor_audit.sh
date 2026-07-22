#!/usr/bin/env bash
# test_eval_archive_sensor_audit.sh — regression sensor for issue #337
# feature `retarget-archive-sensors` (epic #331, decision 3a).
#
# Feature 1 (`archive-evaluation-docs`) moved the zero-runtime-reference eval
# docs and retargeted the four sensors mechanically coupled to those paths by
# name, plus corrected the two kept schemas' embedded `.redaction.authorities[]`
# pointers. This sensor is the executable audit that Feature 2 owns: it proves
# — behaviorally, not by re-reading the plan — that:
#
#   1. The archived governance pointers embedded in the kept schemas
#      (log-schema.v1.json, trace-schema.v1.json) name EXACTLY the archived
#      location set (no missing entry, no extra non-archive entry that
#      happens to resolve) AND every surviving entry resolves to a real file.
#   2. `scripts/affected-sensors.sh` (issue #343), run against the pre-move
#      basenames of the archived governance/telemetry docs, returns exactly
#      the sensor set this audit has verified by hand — no surprise sensor
#      was missed, and none silently dropped out of scope.
#   3. The trace/log schema gates (`test_trace_schema.sh`, `test_log_schema.sh`)
#      stay green — the redaction-authority substring assertions were not
#      weakened by the retarget.
#   4. The L0-directory-contract sensors the issue calls out as precedent
#      (`test_eval_dir_contract.sh`, `test_l0_manifests.sh`) stay green and
#      unchanged — the archival does not leak into L0/l1-solution surfaces.
#
# NOTE on assertion 2: the plan that authored this feature assumed the
# retargeted set was exactly the four path-coupled sensors
# (test_agent_delivery_accuracy_matrix_contract.sh, test_telemetry_retention_docs.sh,
# test_log_pii_governance.sh, test_trace_schema_docs.sh). Re-running
# `scripts/affected-sensors.sh` (issue #343) against the current CLI shows two
# more sensors in the returned set: tests/scripts/test_evaluation_archive_layout.sh
# (its own `archived_paths` enumeration, added by Feature 1, mentions those
# same basenames) and this audit sensor itself (this file's own doc comments
# name those basenames, and `affected-sensors.sh` matches any literal
# basename occurrence anywhere in a tests/scripts|tests/meta shell file — by
# design, its header states "over-inclusion is acceptable, silent
# under-inclusion is not"). Neither addition is a bug: both sensors really do
# encode knowledge of those archived paths. This audit therefore pins the
# verified six-sensor set, not the plan's stale four-sensor assumption.
#
# RED (as authored): asserting the plan's original four-sensor expectation
# against the live `affected-sensors.sh` output fails, because the tool
# reports six sensors. That confirms the plan's literal invocation could not
# be relied on as written and had to be re-verified.
# GREEN: asserting the verified six-sensor set passes.
#
# Exit codes: 0 all four audit obligations verified · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# --- 1. Archived governance pointers embedded in the kept schemas ------------
# Both schemas stayed in docs/evaluation/ (preserved set) but their
# .redaction.authorities[] entries name files the move relocated. Checking
# only that each expected entry is *present* would pass even if the array
# also carried an extra entry that resolves to some coincidentally-real
# docs/evaluation/ (or any other) file — the invariant is that the array
# names EXACTLY the archived set, nothing more and nothing less — so this
# asserts exact set equality, then that every surviving entry resolves.
#
# Bash 3.2 note: `/bin/bash` on macOS ships as 3.2 (last GPLv2 release Apple
# will bundle); `mapfile`/`readarray` are Bash 4+ builtins and exit 127 under
# it. Populate arrays with a `while IFS= read -r` loop over process
# substitution instead — portable to Bash 3.2 and behaviorally identical.
authority_schemas=(
  docs/evaluation/log-schema.v1.json
  docs/evaluation/trace-schema.v1.json
)
expected_authorities=(
  docs/archive/evaluation/security-evals.md
  docs/archive/evaluation/dataset-governance.md
)
expected_authorities_sorted="$(printf '%s\n' "${expected_authorities[@]}" | sort -u)"
for schema in "${authority_schemas[@]}"; do
  [ -f "$schema" ] || { fail "expected authority schema missing: ${schema}"; continue; }
  actual_authorities=()
  while IFS= read -r authority; do
    actual_authorities+=("$authority")
  done < <(jq -r '.redaction.authorities[]' "$schema")

  actual_authorities_sorted="$(printf '%s\n' "${actual_authorities[@]+"${actual_authorities[@]}"}" | sort -u)"
  if [ "$actual_authorities_sorted" != "$expected_authorities_sorted" ]; then
    fail "${schema}: .redaction.authorities[] must name exactly the archived paths (no missing, no extra entries)
--- expected ---
${expected_authorities_sorted}
--- actual ---
${actual_authorities_sorted}"
  fi

  for actual in "${actual_authorities[@]+"${actual_authorities[@]}"}"; do
    [ -e "$actual" ] \
      || fail "${schema}: .redaction.authorities[] entry '${actual}' does not resolve to a real file"
  done
done

# --- 2. affected-sensors.sh reports the verified, not the assumed, set -------
# Pre-move basenames of the three archived docs that a prior sensor sweep
# found path-coupled: telemetry-retention-pii.md, trace-action-log-evals.md,
# and agent-delivery-accuracy-matrix.v1.json. The expected set below is the
# verified six sensors: the four originally retargeted path-coupled sensors,
# the Feature 1 layout sensor (which enumerates those basenames), and this
# audit sensor (whose own doc comments name them — see the NOTE above).
verified_affected_sensors=(
  tests/meta/test_agent_delivery_accuracy_matrix_contract.sh
  tests/scripts/test_eval_archive_sensor_audit.sh
  tests/scripts/test_evaluation_archive_layout.sh
  tests/scripts/test_log_pii_governance.sh
  tests/scripts/test_telemetry_retention_docs.sh
  tests/scripts/test_trace_schema_docs.sh
)
reported_sensors=()
while IFS= read -r sensor; do
  reported_sensors+=("$sensor")
done < <(
  scripts/affected-sensors.sh -- \
    docs/evaluation/telemetry-retention-pii.md \
    docs/evaluation/trace-action-log-evals.md \
    docs/evaluation/agent-delivery-accuracy-matrix.v1.json \
    | sort -u
)
expected_sorted="$(printf '%s\n' "${verified_affected_sensors[@]}" | sort -u)"
actual_sorted="$(printf '%s\n' "${reported_sensors[@]+"${reported_sensors[@]}"}" | sort -u)"
if [ "$actual_sorted" != "$expected_sorted" ]; then
  fail "scripts/affected-sensors.sh returned an unexpected sensor set:
--- expected ---
${expected_sorted}
--- actual ---
${actual_sorted}"
fi

# --- 3. Trace/log schema gates stay green -------------------------------------
schema_sensors=(
  tests/scripts/test_trace_schema.sh
  tests/scripts/test_log_schema.sh
)
for sensor in "${schema_sensors[@]}"; do
  [ -f "$sensor" ] || { fail "expected schema sensor missing: ${sensor}"; continue; }
  bash "$sensor" >/dev/null 2>&1 \
    || fail "${sensor} must stay green after the archive retarget (redaction-authority gate must not weaken)"
done

# --- 4. L0/l1-related sensors remain unaffected -------------------------------
l0_sensors=(
  tests/scripts/test_eval_dir_contract.sh
  tests/scripts/test_l0_manifests.sh
)
for sensor in "${l0_sensors[@]}"; do
  [ -f "$sensor" ] || { fail "expected L0 sensor missing: ${sensor}"; continue; }
  bash "$sensor" >/dev/null 2>&1 \
    || fail "${sensor} must stay green — the docs/evaluation archival must not leak into L0/l1-solution surfaces"
done

if [ "$fails" -ne 0 ]; then
  printf '\n%d evaluation-archive-sensor-audit violation(s).\n' "$fails" >&2
  exit 1
fi
echo "archive governance pointers, affected-sensor set, and trace/log/L0 gates verified"
