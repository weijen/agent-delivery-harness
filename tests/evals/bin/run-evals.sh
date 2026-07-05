#!/usr/bin/env bash
# run-evals.sh — L0 eval runner for feature f1-runner-scorecard (issue #62).
#
# Reads one eval-case manifest, validates it against the #61 Manifest Schema,
# runs its grader command, and emits a schema-valid, case-level scorecard to
# STDOUT per docs/evaluation/l0-solution/spec.md § "Scorecard Schema".
#
# Grader mapping:
#   * manifest invalid           -> row status "invalid_manifest"
#   * grader.command exits 0      -> row status "pass"
#   * grader.command exits !=0    -> row status "fail" + failure_type
#                                    "target_failure"
#
# The scorecard is always written to stdout, regardless of the case's blocking
# decision. Feature f2 (not_run / infrastructure_error) and feature f3
# (fail-closed redaction gate) are deliberately out of scope here: redaction is
# self-declared checked:true and the status mapping is limited to
# pass/fail/invalid_manifest. The shape is kept open for those later features.
#
# Usage: run-evals.sh <manifest-path>
# Exit codes: 0 case passed (or invalid_manifest reported) · 1 a blocking case
#             failed · 2 usage/argc error. The scorecard is emitted to stdout in
#             all non-usage cases.

set -euo pipefail

RUNNER_VERSION="0.1.0"
SUITE="l0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-manifest.sh"

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <manifest-path>\n' "$(basename "$0")" >&2
  exit 2
fi

MANIFEST="$1"

command -v jq >/dev/null 2>&1 \
  || { printf 'error: jq is required but was not found on PATH\n' >&2; exit 1; }

# --- Environment-derived, manifest-independent scorecard fields ----------------
run_id="local-$(date -u +%Y%m%dT%H%M%SZ)"

runtime="${RUN_EVALS_RUNTIME:-local}"
case "$runtime" in
  local | github-pr | github-actions | azure-l1-nightly) ;;
  *) runtime="local" ;;
esac

commit_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)"
[ -n "$commit_sha" ] || commit_sha="unknown"

bash_version="${BASH_VERSION:-unknown}"
git_version="$(git --version 2>/dev/null || echo unknown)"
jq_version="$(jq --version 2>/dev/null || echo unknown)"

# --- Safe manifest field reader ------------------------------------------------
# Emits the raw string value or an empty string; never aborts under set -e even
# when the manifest is unparseable (the invalid_manifest path relies on this).
mf() {
  jq -r "$1 // empty" "$MANIFEST" 2>/dev/null || true
}

# manifest_version and blocking captured as JSON literals (number/bool or null).
manifest_version_json="$(jq '.schema_version // null' "$MANIFEST" 2>/dev/null || echo null)"
blocking_json="$(jq '.blocking // null' "$MANIFEST" 2>/dev/null || echo null)"

case_id="$(mf '.id')"
target="$(mf '.target')"
capability="$(mf '.capability')"
boundary="$(mf '.boundary')"
label="$(mf '.expected_outcome')"
grader_type="$(mf '.grader.type')"
grader_cmd="$(mf '.grader.command')"

# --- Grade the case ------------------------------------------------------------
status=""
failure_type_json="null"
declare -a evidence=()
duration_ms=0

if [ ! -f "$MANIFEST" ] || ! "$VALIDATOR" "$MANIFEST" >/dev/null 2>&1; then
  # Manifest failed schema validation (or is missing): report an
  # invalid_manifest row; do not run the grader.
  status="invalid_manifest"
  evidence=("manifest failed schema validation")
else
  start="$(date +%s)"
  rc=0
  bash -c "$grader_cmd" >/dev/null 2>/dev/null || rc=$?
  end="$(date +%s)"
  duration_ms=$(( (end - start) * 1000 ))

  if [ "$rc" -eq 0 ]; then
    status="pass"
    evidence=("grader command exited 0")
  else
    status="fail"
    failure_type_json='"target_failure"'
    evidence=("grader command exited ${rc}")
  fi
fi

prediction="$status"

# Evidence array as a JSON array literal built element by element (bash-3.2
# portable: no mapfile/readarray). Each element is a short, clean string.
evidence_json="$(printf '%s\n' "${evidence[@]+"${evidence[@]}"}" \
  | jq -R . | jq -s .)"

# --- Assemble the scorecard ----------------------------------------------------
scorecard="$(jq -n \
  --argjson schema_version 1 \
  --arg run_id "$run_id" \
  --arg commit_sha "$commit_sha" \
  --arg runtime "$runtime" \
  --arg runner_version "$RUNNER_VERSION" \
  --arg suite "$SUITE" \
  --arg manifest_path "$MANIFEST" \
  --argjson manifest_version "$manifest_version_json" \
  --arg bash_version "$bash_version" \
  --arg git_version "$git_version" \
  --arg jq_version "$jq_version" \
  --arg case_id "$case_id" \
  --arg target "$target" \
  --arg capability "$capability" \
  --arg boundary "$boundary" \
  --arg label "$label" \
  --arg prediction "$prediction" \
  --arg grader_type "$grader_type" \
  --arg status "$status" \
  --argjson blocking "$blocking_json" \
  --argjson trials 1 \
  --argjson duration_ms "$duration_ms" \
  --argjson failure_type "$failure_type_json" \
  --argjson evidence "$evidence_json" \
  '
  def orNull($s): if ($s == "") then null else $s end;
  ($status == "pass") as $passed |
  {
    schema_version: $schema_version,
    run_id: $run_id,
    commit_sha: $commit_sha,
    runtime: $runtime,
    runner_version: $runner_version,
    suite: $suite,
    manifest_path: $manifest_path,
    manifest_version: $manifest_version,
    fixture_path: null,
    fixture_version: null,
    fixture_hash: null,
    dataset_version: null,
    tool_versions: {
      bash: $bash_version,
      git: $git_version,
      jq: $jq_version
    },
    redaction: {
      checked: true,
      secrets_found: false,
      environment_identifiers_found: false
    },
    results: [
      {
        case_id: orNull($case_id),
        target: orNull($target),
        capability: orNull($capability),
        boundary: orNull($boundary),
        label: orNull($label),
        prediction: $prediction,
        observable_signal: ["exit_code"],
        grader: orNull($grader_type),
        status: $status,
        blocking_decision: (
          if $status == "pass" then "pass"
          elif ($blocking == true) then "block"
          else "warn"
          end
        ),
        trials: $trials,
        duration_ms: $duration_ms,
        skip_reason: null,
        failure_type: $failure_type,
        evidence: $evidence
      }
    ],
    aggregates: {
      total_cases: 1,
      passed: (if $passed then 1 else 0 end),
      failed: (if $status == "fail" then 1 else 0 end),
      skipped: 0,
      false_positive: 0,
      false_negative: 0
    }
  }
  ')"

printf '%s\n' "$scorecard"

# Exit non-zero for a blocking case failure, but only after the scorecard has
# been emitted to stdout (the sensor asserts on stdout independently of exit).
if [ "$status" = "fail" ] && [ "$blocking_json" = "true" ]; then
  exit 1
fi

exit 0
