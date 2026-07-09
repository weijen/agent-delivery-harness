#!/usr/bin/env bash
# test_copilot_subagent_env_and_allowlist.sh — regression sensor for issue #227
# feature path-o-env-and-docs (Task 4). Pins the wiring that lets the harness
# turn Path O enrichment ON and ship the resulting attribute:
#
#   1. .env.example is TRACKED, carries the COPILOT_OTEL_* placeholders the hook
#      reads (COPILOT_OTEL_ENABLED, COPILOT_OTEL_FILE_EXPORTER_PATH), documents
#      the single `set -a; source .env; set +a` load idiom, and holds NO real
#      secret (this is the shared .env mechanism #238 later extends — one file,
#      one load path, never auto-sourced).
#   2. The OTel file-export sink dir (.copilot-tracking/otel/) is git-ignored.
#   3. harness.subagent rides the trace-export allowlist AND is documented in
#      the schema contract (the allowlist ⊆ documented invariant, Q5).
#
# Exit codes: 0 the Task-4 wiring holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_EXAMPLE="${ROOT}/.env.example"
GITIGNORE="${ROOT}/.gitignore"
EXPORT="${ROOT}/scripts/trace-export.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"
[ -f "$EXPORT" ] || fail "scripts/trace-export.sh not found"
[ -f "$CONTRACT" ] || fail "trace schema contract not found"

# --- 1. .env.example -----------------------------------------------------------
[ -f "$ENV_EXAMPLE" ] || fail ".env.example must exist (tracked template for local OTel + export config)"
( cd "$ROOT" && git ls-files --error-unmatch .env.example >/dev/null 2>&1 ) \
  || fail ".env.example must be TRACKED (git ls-files) — it is the committed template"

grep -qE '^[[:space:]]*#?[[:space:]]*COPILOT_OTEL_ENABLED=' "$ENV_EXAMPLE" \
  || fail ".env.example must carry a COPILOT_OTEL_ENABLED placeholder"
grep -qE '^[[:space:]]*#?[[:space:]]*COPILOT_OTEL_FILE_EXPORTER_PATH=' "$ENV_EXAMPLE" \
  || fail ".env.example must carry a COPILOT_OTEL_FILE_EXPORTER_PATH placeholder (the hook reads this)"
grep -qiE 'set -a|source .*\.env|so(u)?rce' "$ENV_EXAMPLE" \
  || fail ".env.example must document the explicit load idiom (set -a; source .env; set +a) — env is never auto-sourced"

# No real secret shape may sit in the committed template.
if grep -qiE 'InstrumentationKey=[0-9a-f]{8}-|AccountKey=|-----BEGIN|password[[:space:]]*=[[:space:]]*[^[:space:]#]' "$ENV_EXAMPLE"; then
  fail ".env.example must NOT contain a real secret (connection string / key / password value)"
fi

# --- 2. OTel sink dir ignored --------------------------------------------------
[ -f "$GITIGNORE" ] || fail ".gitignore not found"
( cd "$ROOT" && git check-ignore -q ".copilot-tracking/otel/probe.jsonl" ) \
  || fail ".copilot-tracking/otel/ must be git-ignored (local OTel file-export sink is never committed)"

# --- 3. harness.subagent shippable + documented --------------------------------
allowlist_slice="$(sed -n '/def allowlist:/,/\];/p' "$EXPORT")"
printf '%s' "$allowlist_slice" | grep -qF '"harness.subagent"' \
  || fail "harness.subagent must be in the trace-export allowlist (Q5: split conductor-vs-subagent in App Insights)"

jq -e '.optional_fields | has("harness.subagent")' "$CONTRACT" >/dev/null \
  || fail "harness.subagent must be documented in the schema contract optional_fields (allowlist ⊆ documented invariant)"

printf 'PASS: .env.example carries COPILOT_OTEL_* placeholders (no secret), .copilot-tracking/otel/ is ignored, and harness.subagent is allowlisted + documented\n'
