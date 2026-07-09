#!/usr/bin/env bash
# test_export_env_docs.sh — doc sensor for the local .env setup section
# (issue #238, feature export-env-docs).
#
# #238 asks the OTLP/Azure Monitor adapter doc to teach the three local flows
# for turning trace export on without leaking the secret:
#   1. one-time / generated setup  → scripts/gen-export-env.sh
#   2. manual export run           → set the vars + scripts/trace-export.sh
#   3. closeout export             → finish-issue picks the vars up
# plus the load idiom (`set -a; source .env; set +a`) and the never-commit
# warning, all anchored on the ONE shared .env / .env.example file.
#
# Exit codes: 0 the doc covers the flows · 1 an obligation is undocumented.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/runtime-adapters/otlp-azure-monitor.md"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$DOC" ] || fail "doc not found (${DOC})"

# A dedicated Local .env setup section must exist.
grep -qiE '^##+ .*local .*\.env|^##+ .*\.env .*setup' "$DOC" \
  || fail "doc must have a 'Local .env setup' section heading"

# The generator script must be named.
grep -qF 'scripts/gen-export-env.sh' "$DOC" \
  || fail "doc must reference the generator scripts/gen-export-env.sh"

# The shared template + local file must both be named (one shared file).
grep -qF '.env.example' "$DOC" || fail "doc must reference the tracked .env.example template"
grep -qE '(^|[^.])\.env\b' "$DOC" || fail "doc must reference the local .env file"

# The load idiom must be shown (allow flexible spacing around ';').
grep -qE 'set -a *; *(source|\.) +\.env *; *set \+a' "$DOC" \
  || fail "doc must show the 'set -a; source .env; set +a' load idiom"

# All three flows must be described: generated setup, manual export, closeout.
grep -qF 'trace-export.sh' "$DOC" || fail "doc must cover the manual export flow (trace-export.sh)"
grep -qiE 'finish-issue|closeout' "$DOC" || fail "doc must cover the closeout export flow (finish-issue)"

# Issue #244: closeout must be documented as auto-loading the main-checkout .env,
# unlike manual/start flows that still require an explicit source step.
grep -qiE '(finish-issue|closeout).*(auto-load|automatically loads|reads? the main[- ]checkout [`'\'']?\.env|loads? the main[- ]checkout [`'\'']?\.env)|(auto-load|automatically loads|reads? the main[- ]checkout [`'\'']?\.env|loads? the main[- ]checkout [`'\'']?\.env).*(finish-issue|closeout)' "$DOC" \
  || fail "doc must say finish-issue closeout auto-loads/reads the main-checkout .env"

# After the one-time generator setup, closeout should not require manually
# sourcing .env in the shell that runs finish-issue.
grep -qiE '(gen-export-env\.sh|one-time|generated setup).*(finish-issue|closeout).*(no manual source|without manually source|without source|no .*source)|(finish-issue|closeout).*(gen-export-env\.sh|one-time|generated setup).*(no manual source|without manually source|without source|no .*source)' "$DOC" \
  || fail "doc must say one gen-export-env.sh setup avoids manual source for closeout"

# The closeout loader is constrained: either document the trace-export key
# allowlist or that process environment still overrides .env at closeout.
grep -qiE '(allowlist|allow-listed).*(TRACE_EXPORT_OTLP|APPLICATIONINSIGHTS_CONNECTION_STRING|trace-export keys|export variables)|process env(ironment)?.*(overrides|wins).*(\.env|closeout)' "$DOC" \
  || fail "doc must document the closeout .env allowlist or process-env override"

# Never-commit warning must be present.
grep -qiE 'never commit|do not commit|don.t commit' "$DOC" \
  || fail "doc must carry a never-commit-the-secret warning"

printf 'PASS: otlp-azure-monitor.md documents local .env setup, the three flows, load idiom and never-commit\n'
