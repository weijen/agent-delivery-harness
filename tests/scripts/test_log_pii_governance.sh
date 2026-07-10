#!/usr/bin/env bash
# test_log_pii_governance.sh — regression sensor for the step-level log PII
# governance clause (issue #219, feature log-pii-governance).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   L — docs/evaluation/telemetry-retention-pii.md documents the step-level
#       log (`log.jsonl`) as its own PII surface, distinct from exported
#       telemetry:
#   L1. It names BOTH `message` AND `payload` as excluded / redacted
#       free-text fields of the step-level log — asserted in a log-PII
#       context (anchored to a `log.jsonl` / step-level-log heading or row),
#       not merely anywhere in the page.
#   L2. (RECONCILED for issue #220 — the opt-in log EXPORT path.) The RAW
#       `log.jsonl` artifact stays gitignored / local, but what may leave the
#       machine is a governed, redacted+allowlisted PROJECTION, NOT the raw
#       file. The old absolute "log.jsonl is never exported / never ships /
#       stays on the machine" is now FALSE for the projection and is retired;
#       the sensor instead pins BOTH halves of the reconciled truth:
#         L2a. the RAW artifact is gitignored / local-only, AND
#         L2b. a governed *projection* of the log stream is exportable
#              (the raw file itself never ships; the projection does).
#   L3. (NEW — issue #220.) The log stream is now EXPORTABLE opt-in: the log
#       region names `scripts/log-export.sh` as the exporter and the
#       `LOG_EXPORT_OTLP` opt-in gate.
#   L4. (NEW — issue #220.) The exported log envelopes carry the SAME
#       governance as spans, stated in the log region:
#         * redact-before-cap,
#         * the deny-by-default shippable-attribute allowlist, and
#         * the SAME unified retention window — the LIVE Terraform
#           `retention_in_days` default parsed from
#           infra/terraform/variables.tf (both-direction drift check, so the
#           log-export retention statement cannot diverge from the one
#           workspace policy).
#
# RED until the doc's log region documents the exportable log stream +
# same-governance clause (export path, opt-in, deny-by-default allowlist, and
# the live-parsed retention window) and reconciles the raw-artifact vs
# projection distinction.
#
# Exit codes: 0 spec contract honored · 1 an obligation regressed (the doc
# lacks the log-PII governance clause — RED gate for this feature).

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
    printf '\n%d step-level log PII governance contract violation(s).\n' "$fails" >&2
    exit 1
  fi
  printf 'step-level log PII governance contract honored\n'
  exit 0
}

if [ ! -f "$DOC" ]; then
  fail "spec doc not found (${DOC}) — feature log-pii-governance (issue #219) has no doc to govern"
  finish
fi

# --- Parse the LIVE Terraform retention_in_days default (drift source) --------
# The opt-in log export (issue #220) ships under the SAME unified retention
# window as spans, so the log-region retention statement is drift-checked
# against the live Terraform default too — one workspace policy, both signals.
# This reuses the same live-parse the telemetry-retention sensor (D1) uses so
# the two cannot diverge.
if [ ! -f "$VARIABLES_TF" ]; then
  fail "infra/terraform/variables.tf not found (${VARIABLES_TF}) — cannot drift-check the log-export retention window against the live Terraform default (L4)"
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
  fail "could not parse the retention_in_days default from infra/terraform/variables.tf (got '${TF_RETENTION:-<empty>}') — the live drift source is unreadable (L4)"
  finish
fi
printf 'note: live Terraform retention_in_days default = %s\n' "$TF_RETENTION"

# The log-PII clause lives in one region of the page. Isolate that region so
# the field/local-only pins are anchored to the log.jsonl context rather than
# passing on an unrelated mention elsewhere. The region is delimited by the
# first line that references the step-level log up to the next top-level (##)
# heading. It is flattened (newlines -> spaces) so a phrase wrapped across
# markdown lines cannot dodge a multi-word pin.
REGION="$(awk '
  tolower($0) ~ /log\.jsonl|step-level log/ { grabbing = 1 }
  grabbing && /^## / && collected { exit }
  grabbing { print; collected = 1 }
' "$DOC" | tr '\n' ' ')"

if [ -z "$REGION" ]; then
  fail "doc has no step-level log (log.jsonl / 'step-level log') section — the log-PII governance clause is absent (L1/L2)"
  finish
fi

# --- L1. Both free-text log fields named in the log-PII context ---------------
grep -qiE '\bmessage\b' <<<"$REGION" \
  || fail "doc must name the excluded free-text log field 'message' in the log.jsonl context (L1)"
grep -qiE '\bpayload\b' <<<"$REGION" \
  || fail "doc must name the excluded free-text log field 'payload' in the log.jsonl context (L1)"

# The context must be an exclusion/redaction one, not a passing mention.
grep -qiE 'exclud|redact|never ship|not (export|ship)|stripped|omit' <<<"$REGION" \
  || fail "doc must frame message/payload as excluded/redacted free-text fields, not merely mention them (L1)"

# --- L2 (RECONCILED for #220). Raw artifact local; governed projection ships --
# The old absolute pin ("log.jsonl is never exported / stays on the machine")
# is retired: issue #220 introduces an opt-in EXPORT of a redacted+allowlisted
# PROJECTION of the log stream. What is now true — and what this sensor pins —
# is the two-part reconciliation: the RAW artifact stays gitignored/local, but
# a governed PROJECTION (not the raw file) is exportable.
#   L2a — the RAW log.jsonl artifact is gitignored / local-only.
grep -qiE 'gitignore|local[- ]only' <<<"$REGION" \
  || fail "doc must state the RAW log.jsonl artifact is gitignored / local-only (L2a)"
#   L2b — a governed PROJECTION of the log stream is what may be exported
#   (the raw file itself never ships; the redacted+allowlisted projection does).
grep -qiE 'projection' <<<"$REGION" \
  || fail "doc must state that what ships is a governed/redacted PROJECTION of the log stream, not the raw log.jsonl file (L2b — reconciles the retired 'never exported' absolute now that issue #220 adds the opt-in export)"

# --- L3 (NEW, #220). The log stream is EXPORTABLE opt-in --------------------
# scripts/log-export.sh ships the step-level log under the LOG_EXPORT_OTLP
# opt-in gate. Both must be named in the log region so the doc actually
# documents the new export path, not just allude to a future one.
grep -qF -- 'scripts/log-export.sh' <<<"$REGION" \
  || fail "doc log region must name scripts/log-export.sh as the opt-in step-level log exporter (L3)"
grep -qE 'LOG_EXPORT_OTLP' <<<"$REGION" \
  || fail "doc log region must name the LOG_EXPORT_OTLP opt-in gate that enables the log export (L3)"

# --- L4 (NEW, #220). Exported log envelopes carry the SAME governance as spans-
# redact-before-cap + the deny-by-default allowlist + the SAME live-parsed
# unified retention window (drift-checked against Terraform, both directions).
grep -qiE 'redact[- ]before[- ]cap|redact.{0,20}before.{0,20}cap' <<<"$REGION" \
  || fail "doc log region must state the exported log envelopes pass redact-before-cap (same as spans) (L4)"
grep -qiE 'deny[- ]by[- ]default' <<<"$REGION" \
  || fail "doc log region must state the exported log envelopes pass the deny-by-default shippable-attribute allowlist (same as spans) (L4)"
# Forward drift: the log region must state the SAME live Terraform retention day-count.
grep -qE "(^|[^0-9])${TF_RETENTION}([^0-9]|\$)" <<<"$REGION" \
  || fail "doc log region must state the exported log stream shares the SAME unified retention window (${TF_RETENTION} days — the live Terraform retention_in_days default) (L4)"
# Reverse drift: no OTHER 30..730-range retention day-count may appear in the
# log region — the log export cannot claim a window that diverges from the one
# workspace policy.
STALE_LOG="$(grep -oiE '[0-9]{2,3}[[:space:]-]*day' <<<"$REGION" \
  | grep -oE '[0-9]{2,3}' \
  | while read -r n; do
      if [ "$n" -ge 30 ] && [ "$n" -le 730 ] && [ "$n" != "$TF_RETENTION" ]; then
        printf '%s ' "$n"
      fi
    done)"
if [ -n "$STALE_LOG" ]; then
  fail "doc log region states a retention day-count (${STALE_LOG}) that differs from the live Terraform default ${TF_RETENTION} — the exported log window cannot diverge from the unified policy (L4)"
fi

finish
