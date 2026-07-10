#!/usr/bin/env bash
# test_telemetry_retention_docs.sh — regression sensor for the telemetry
# retention + PII governance spec (issue #113, feature
# telemetry-retention-pii-spec).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   D — docs/evaluation/telemetry-retention-pii.md exists and documents:
#   D1. The retention window as a number, and that number MATCHES the
#       Terraform `retention_in_days` default parsed LIVE from
#       infra/terraform/variables.tf. This is a BOTH-DIRECTION drift check:
#       if variables.tf changes the default (e.g. 30 -> 60) the doc must
#       change too; if the doc states a different number than the live
#       Terraform default, the sensor fails.
#   D2. All FIVE allowlist-excluded fields, BY NAME
#       (harness.args_summary, harness.result_summary, harness.summary,
#        harness.worktree, harness.branch) — the same five the exporter (#112) drops
#       deny-by-default.
#   D3. The 'deny-by-default' policy language AND a deletion/purge path
#       (the telemetry auditability / rollback story).
#   D4. Cross-links to the four sibling governance docs:
#         * docs/evaluation/dataset-governance.md
#         * docs/evaluation/security-evals.md
#         * docs/runtime-adapters/otlp-azure-monitor.md
#         * infra/terraform/README.md
#   D5. (issue #220 — the opt-in log EXPORT path.) The step-level-log region
#       documents that the exported log stream (`scripts/log-export.sh`) is
#       governed by the SAME unified retention window — the LIVE Terraform
#       `retention_in_days` default — so the one workspace policy cannot
#       diverge between the span and log signals (both-direction drift, scoped
#       to the log region).
#
# RED until docs/evaluation/telemetry-retention-pii.md exists.
#
# Exit codes: 0 spec contract honored · 1 an obligation regressed (or the
# doc is missing — RED gate for this feature).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/evaluation/telemetry-retention-pii.md"
VARIABLES_TF="${ROOT}/infra/terraform/variables.tf"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

finish() {
  if [ "$fails" -ne 0 ]; then
    printf '\n%d telemetry retention/PII spec contract violation(s).\n' "$fails" >&2
    exit 1
  fi
  printf 'telemetry retention/PII spec contract honored\n'
  exit 0
}

# --- Parse the LIVE Terraform retention_in_days default (drift source) --------
# Extract the `default = <N>` line from inside the `retention_in_days`
# variable block. awk isolates the block so a `default` in another variable
# cannot be mismatched; the value is validated as an integer before use.
if [ ! -f "$VARIABLES_TF" ]; then
  fail "infra/terraform/variables.tf not found (${VARIABLES_TF}) — cannot parse the retention_in_days default to drift-check the doc against"
  finish
fi
TF_RETENTION="$(awk '
  /variable[[:space:]]+"retention_in_days"/ { inblk = 1 }
  inblk && /^[[:space:]]*default[[:space:]]*=/ {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+$/) { print $i; exit }
    }
  }
  inblk && /^}/ { inblk = 0 }
' "$VARIABLES_TF")"
if ! [[ "$TF_RETENTION" =~ ^[0-9]+$ ]]; then
  fail "could not parse the retention_in_days default from infra/terraform/variables.tf (got '${TF_RETENTION:-<empty>}') — the live drift source is unreadable"
  finish
fi
printf 'note: live Terraform retention_in_days default = %s\n' "$TF_RETENTION"

# ==============================================================================
# RED gate: the spec doc must exist before content pins can run.
# ==============================================================================
if [ ! -f "$DOC" ]; then
  fail "spec doc not found (${DOC}) — feature telemetry-retention-pii-spec (issue #113) is not implemented yet"
  finish
fi

# Markdown wraps prose: multi-word phrase pins run against a
# newline-flattened copy so a line break inside a phrase cannot dodge them.
FLAT="$(mktemp)"
trap 'rm -f "${FLAT}"' EXIT
tr '\n' ' ' < "$DOC" > "$FLAT"

# ==============================================================================
# D1. Retention window matches the LIVE Terraform default (both directions).
#     Forward: the doc must state the live default number.
#     Reverse: the doc must NOT state a *different* retention-day number
#     against the retention_in_days knob — a stale doc (e.g. still says 30
#     after Terraform moved to 60) fails here.
# ==============================================================================
if grep -qE "(^|[^0-9])${TF_RETENTION}([^0-9]|\$)" "$DOC"; then
  printf 'note: doc states the live retention window (%s days)\n' "$TF_RETENTION"
else
  fail "doc must state the retention window as ${TF_RETENTION} — the LIVE retention_in_days default in infra/terraform/variables.tf (both-direction drift: change Terraform and the doc must follow) (D1)"
fi
grep -qiE 'retention_in_days|retention' "$DOC" \
  || fail "doc must tie the retention window to the Terraform retention_in_days knob (D1)"
# Reverse drift: scan for any other 30..730-range number attached to a
# days/retention word that contradicts the live default. A number in that
# window that is NOT the live default is a stale/hand-edited retention claim.
STALE="$(grep -oiE '[0-9]{2,3}[[:space:]-]*day' "$FLAT" \
  | grep -oE '[0-9]{2,3}' \
  | while read -r n; do
      if [ "$n" -ge 30 ] && [ "$n" -le 730 ] && [ "$n" != "$TF_RETENTION" ]; then
        printf '%s ' "$n"
      fi
    done)"
if [ -n "$STALE" ]; then
  fail "doc states a retention day-count (${STALE}) that differs from the live Terraform default ${TF_RETENTION} — stale drift, both directions must agree (D1)"
fi

# ==============================================================================
# D2. All five allowlist-excluded fields named explicitly.
# ==============================================================================
for excluded in 'harness.args_summary' 'harness.result_summary' 'harness.summary' 'harness.worktree' 'harness.branch'; do
  grep -qF -- "$excluded" "$DOC" \
    || fail "doc must name the excluded field ${excluded} explicitly (the exporter drops all five deny-by-default) (D2)"
done

# ==============================================================================
# D3. Deny-by-default policy + a deletion / purge path.
# ==============================================================================
grep -qiE 'deny[- ]by[- ]default|denied by default' "$FLAT" \
  || fail "doc must state the shippable-attribute allowlist is deny-by-default (D3)"
grep -qiE 'delet(e|ion)|purge|scrub|rollback' "$FLAT" \
  || fail "doc must describe a deletion/purge path for telemetry (the auditability / rollback story) (D3)"

# ==============================================================================
# D4. Cross-links to the four sibling governance docs.
# ==============================================================================
for link in \
  'docs/evaluation/dataset-governance.md' \
  'docs/evaluation/security-evals.md' \
  'docs/runtime-adapters/otlp-azure-monitor.md' \
  'infra/terraform/README.md'; do
  grep -qF -- "$link" "$DOC" \
    || fail "doc must cross-link ${link} (D4)"
done

# ==============================================================================
# D5. The opt-in log export (issue #220) shares the SAME live-parsed retention
#     window. Scoped to the step-level-log region so it pins the log-export
#     retention statement (not merely the span window). Both directions:
#     forward — the log region states the live default; reverse — no divergent
#     retention day-count may appear in the log region. One workspace policy,
#     one number, for both the span and log signals.
# ==============================================================================
LOG_REGION="$(awk '
  tolower($0) ~ /log\.jsonl|step-level log/ { grabbing = 1 }
  grabbing && /^## / && collected { exit }
  grabbing { print; collected = 1 }
' "$DOC" | tr '\n' ' ')"
if [ -z "$LOG_REGION" ]; then
  fail "doc has no step-level log (log.jsonl / 'step-level log') region — cannot confirm the opt-in log export shares the unified retention window (D5)"
else
  grep -qF -- 'scripts/log-export.sh' <<<"$LOG_REGION" \
    || fail "doc log region must name scripts/log-export.sh as the opt-in log exporter governed by this retention policy (D5)"
  grep -qE "(^|[^0-9])${TF_RETENTION}([^0-9]|\$)" <<<"$LOG_REGION" \
    || fail "doc log region must state the exported log stream shares the SAME unified retention window (${TF_RETENTION} days — the live Terraform retention_in_days default) (D5)"
  STALE_LOG="$(grep -oiE '[0-9]{2,3}[[:space:]-]*day' <<<"$LOG_REGION" \
    | grep -oE '[0-9]{2,3}' \
    | while read -r n; do
        if [ "$n" -ge 30 ] && [ "$n" -le 730 ] && [ "$n" != "$TF_RETENTION" ]; then
          printf '%s ' "$n"
        fi
      done)"
  if [ -n "$STALE_LOG" ]; then
    fail "doc log region states a retention day-count (${STALE_LOG}) that differs from the live Terraform default ${TF_RETENTION} — the exported log window cannot diverge from the unified policy (D5)"
  fi
fi

finish
