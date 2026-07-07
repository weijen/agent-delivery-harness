#!/usr/bin/env bash
# test_trace_export_docs.sh — regression sensor for the OTLP / Azure Monitor
# exporter adapter doc and core decoupling (issue #112, feature
# trace-export-adapter-docs, plan Phase 4).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   D — docs/runtime-adapters/otlp-azure-monitor.md exists and documents:
#   D1. Env contract: TRACE_EXPORT_OTLP=1 opt-in;
#       APPLICATIONINSIGHTS_CONNECTION_STRING sourced from
#       `terraform output -raw connection_string`; an explicit
#       never-commit-the-connection-string statement.
#   D2. The span→envelope mapping table: all four span types, both envelope
#       names (Microsoft.ApplicationInsights.RemoteDependency / .Event),
#       both baseTypes (RemoteDependencyData / EventData), customDimensions
#       and measurements, and harness.version as the queryable dimension
#       (with a KQL example slicing on customDimensions).
#   D3. The allowlist policy: deny-by-default language, the four explicit
#       exclusions BY NAME (harness.args_summary, harness.summary,
#       harness.worktree, harness.branch) with rationale wording, and the
#       revisit-in-#113 note.
#   D4. The HONEST framing: App-Insights-native Track(-API) envelopes
#       carrying OTel attribute names — explicitly NOT wire/raw OTLP; native
#       OTLP ingestion needs a different resource shape (DCR/DCE) plus
#       Microsoft Entra auth, and is a future opt-in requiring a Terraform
#       revision.
#   D5. Fail-closed gate semantics: fail-closed wording, nothing written on
#       gate failure, and the ONE tolerance (invalid_json-only findings are
#       skip-and-counted, anything else refuses).
#   D6. The local-only live smoke recipe: a dry-run step
#       (--dry-run-to-file), a ship invocation, and a KQL verification —
#       explicitly local-only / not CI-run. (Step ORDER is prose, not
#       machine-pinned: D2 legitimately places a KQL example in the mapping
#       section before the recipe, so a line-order assertion would conflict
#       with D2.)
#   D7. Cross-links: infra/terraform/README.md and at least one
#       runtime-adapters sibling doc (claude-code.md / github-copilot.md).
#   D8. The dry-run seam disclaimer is documented: the output file is an
#       internal seam, not a stable contract.
#
#   T — zero core coupling (#96 T3 style): no script under scripts/*.sh
#       other than trace-export.sh itself references 'trace-export' — the
#       exporter is opt-in and never wired into the lifecycle, WITH ONE
#       sanctioned exception: finish-issue.sh performs a best-effort closeout
#       export (issue #144), so it may reference trace-export. Every OTHER
#       core script must stay decoupled. (Tests and docs are exempt by
#       construction: only scripts/ is scanned.)
#
# The coupling leg runs FIRST so a RED report shows both the decoupling
# status and the missing doc. RED while the doc does not exist.
#
# Exit codes: 0 doc + decoupling contract honored · 1 an obligation
# regressed (or the doc is missing — RED gate for this feature).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/runtime-adapters/otlp-azure-monitor.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

finish() {
  if [ "$fails" -ne 0 ]; then
    printf '\n%d trace-export adapter-docs contract violation(s).\n' "$fails" >&2
    exit 1
  fi
  printf 'trace-export adapter doc + decoupling contract honored\n'
  exit 0
}

# ==============================================================================
# T. Zero core coupling (#96 T3 style): the exporter is never wired into the
#    lifecycle — no core script references it.
# ==============================================================================
coupled=""
for script in "${ROOT}"/scripts/*.sh; do
  case "$(basename "$script")" in
    # trace-export.sh is the exporter itself. finish-issue.sh is the ONE
    # sanctioned lifecycle caller: it wires a best-effort closeout export
    # (issue #144) that no-ops unless configured and never blocks teardown.
    # Every OTHER core script must stay decoupled, so they are still scanned.
    trace-export.sh | finish-issue.sh) continue ;;
  esac
  if grep -q 'trace-export' "$script"; then
    coupled="${coupled} $(basename "$script")"
  fi
done
[ -z "$coupled" ] \
  || fail "core lifecycle scripts must not reference trace-export (opt-in decoupling doctrine):${coupled}"

# ==============================================================================
# RED gate: the adapter doc must exist before content pins can run.
# ==============================================================================
if [ ! -f "$DOC" ]; then
  fail "adapter doc not found (${DOC}) — feature trace-export-adapter-docs (issue #112 Phase 4) is not implemented yet"
  finish
fi

# Markdown wraps prose: multi-word phrase pins run against a
# newline-flattened copy so a line break inside a phrase cannot dodge them.
FLAT="$(mktemp)"
trap 'rm -f "${FLAT}"' EXIT
tr '\n' ' ' < "$DOC" > "$FLAT"

# ==============================================================================
# D1. Env contract.
# ==============================================================================
grep -qF 'TRACE_EXPORT_OTLP=1' "$DOC" \
  || fail "doc must document the TRACE_EXPORT_OTLP=1 opt-in flag (D1)"
grep -qF 'APPLICATIONINSIGHTS_CONNECTION_STRING' "$DOC" \
  || fail "doc must document APPLICATIONINSIGHTS_CONNECTION_STRING (D1)"
grep -qE 'terraform output( -raw)? connection_string' "$FLAT" \
  || fail "doc must show sourcing the connection string via terraform output (-raw) connection_string (D1)"
grep -qiE 'never commit|do not commit|must not (be )?commit' "$FLAT" \
  || fail "doc must state the connection string is never committed (D1)"

# ==============================================================================
# D2. Mapping table + queryable dimension.
# ==============================================================================
for token in 'Microsoft.ApplicationInsights.RemoteDependency' 'RemoteDependencyData' \
  'Microsoft.ApplicationInsights.Event' 'EventData' \
  'customDimensions' 'measurements' 'harness.version'; do
  grep -qF "$token" "$DOC" \
    || fail "doc mapping table must mention ${token} (D2)"
done
for span in tool lifecycle agent model; do
  grep -qE "\`?${span}\`?" "$DOC" \
    || fail "doc mapping table must cover the '${span}' span type (D2)"
done
grep -qi 'KQL' "$DOC" \
  || fail "doc must include a KQL example (D2)"
grep -qE 'customDimensions\[' "$DOC" \
  || fail "doc's KQL example must slice on customDimensions[...] (D2)"

# ==============================================================================
# D3. Allowlist policy + explicit exclusions + #113 revisit note.
# ==============================================================================
grep -qiE 'allow[- ]?list' "$DOC" \
  || fail "doc must describe the shippable-attribute allowlist (D3)"
grep -qiE 'deny[- ]by[- ]default|denied by default' "$FLAT" \
  || fail "doc must state the allowlist is deny-by-default (D3)"
for excluded in 'harness.args_summary' 'harness.summary' 'harness.worktree' 'harness.branch'; do
  grep -qF -- "$excluded" "$DOC" \
    || fail "doc must name the excluded field ${excluded} explicitly (D3)"
done
grep -qiE 'free[- ]text|leak' "$DOC" \
  || fail "doc must give the exclusion rationale (free-text / leak surface wording) (D3)"
grep -qF '#113' "$DOC" \
  || fail "doc must carry the revisit-in-#113 note for the excluded fields (D3)"

# ==============================================================================
# D4. Honest framing: Track envelopes, NOT wire-OTLP; native OTLP needs
#     DCR/DCE + Entra and a Terraform revision (future opt-in).
# ==============================================================================
grep -qiE 'track api|track envelopes|v2/track' "$FLAT" \
  || fail "doc must name the Application Insights Track API transport (D4)"
grep -qiE 'not[^.]{0,40}(wire|raw)[- ]OTLP|(wire|raw)[- ]OTLP[^.]{0,20}is not' "$FLAT" \
  || fail "doc must state explicitly this is NOT wire/raw OTLP (honest framing, D4)"
grep -qiE 'OTel|OpenTelemetry' "$DOC" \
  || fail "doc must explain the OTel-conventional attribute names framing (D4)"
grep -qiE 'DCR|data collection rule' "$FLAT" \
  || fail "doc must note native OTLP ingestion needs a DCR/DCE resource shape (D4)"
grep -qi 'Entra' "$DOC" \
  || fail "doc must note native OTLP ingestion needs Microsoft Entra auth (D4)"
grep -qi 'Terraform' "$DOC" \
  || fail "doc must note the future native-OTLP opt-in requires a Terraform revision (D4)"

# ==============================================================================
# D5. Fail-closed gate semantics incl. the invalid_json-only tolerance.
# ==============================================================================
grep -qiE 'fail[- ]closed|fails closed' "$FLAT" \
  || fail "doc must describe the fail-closed export gate (D5)"
grep -qiE 'nothing (is )?(written|shipped|leaves)' "$FLAT" \
  || fail "doc must state a gate failure writes/ships nothing (D5)"
grep -qF 'invalid_json' "$DOC" \
  || fail "doc must document the invalid_json-only tolerance (skip-and-count) vs refusal for every other violation class (D5)"

# ==============================================================================
# D6. Local-only live smoke recipe: dry-run, then ship, then KQL — in order.
# ==============================================================================
grep -qF -- '--dry-run-to-file' "$DOC" \
  || fail "doc's smoke recipe must start with --dry-run-to-file (D6)"
grep -qE '(scripts/)?trace-export\.sh' "$DOC" \
  || fail "doc's smoke recipe must show invoking scripts/trace-export.sh (D6)"
grep -qiE 'local[- ]only|never (runs? )?in CI|not (run|runs) in CI|outside CI' "$FLAT" \
  || fail "doc must mark the live smoke as local-only / not CI-run (D6)"

# ==============================================================================
# D7. Cross-links to the env-contract source and the adapter family.
# ==============================================================================
grep -qF 'infra/terraform/README.md' "$DOC" \
  || fail "doc must cross-link infra/terraform/README.md (the env-contract source) (D7)"
grep -qE 'claude-code\.md|github-copilot\.md' "$DOC" \
  || fail "doc must cross-link at least one runtime-adapters sibling doc (D7)"

# ==============================================================================
# D8. The dry-run seam disclaimer is documented in prose too.
# ==============================================================================
grep -qiE 'internal seam' "$FLAT" \
  || fail "doc must describe the dry-run output file as an internal seam (D8)"
grep -qiE 'not a stable contract' "$FLAT" \
  || fail "doc must state the dry-run format is not a stable contract (D8)"

# ==============================================================================
# D9. Native OTLP/HTTP transport (issue #151): an ADDITIONAL opt-in transport
#     alongside the unchanged Application Insights Track API path, still wired
#     to nothing in the lifecycle (decoupling doctrine), with
#     never-commit-secrets discipline on its auth-headers env var. Concepts,
#     not exact prose — tolerant/case-insensitive greps.
# ==============================================================================
grep -qF 'TRACE_EXPORT_OTLP_HTTP' "$DOC" \
  || fail "doc must document the TRACE_EXPORT_OTLP_HTTP opt-in flag for the native OTLP/HTTP transport (D9, #151)"
grep -qF 'OTEL_EXPORTER_OTLP_ENDPOINT' "$DOC" \
  || fail "doc must document the OTEL_EXPORTER_OTLP_ENDPOINT endpoint env var (D9, #151)"
grep -qF -- '/v1/traces' "$DOC" \
  || fail "doc must document the OTLP/HTTP /v1/traces path (D9, #151)"
grep -qi 'opt-in' "$DOC" \
  || fail "doc must frame the native OTLP/HTTP transport as opt-in (D9, #151)"
grep -qiE 'decoupl|never[^.]{0,60}lifecycle|lifecycle[^.]{0,60}never' "$FLAT" \
  || fail "doc must state the OTLP/HTTP transport is never wired into the lifecycle (decoupling doctrine) (D9, #151)"
grep -qF 'OTEL_EXPORTER_OTLP_HEADERS' "$DOC" \
  || fail "doc must document the OTEL_EXPORTER_OTLP_HEADERS env var for auth headers (D9, #151)"
grep -qiE 'never commit|do not commit|secret|token' "$FLAT" \
  || fail "doc must carry a never-commit-secrets warning for OTLP/HTTP headers/tokens (D9, #151)"
grep -qiE 'Track API|Application Insights' "$DOC" \
  || fail "doc must reference the unchanged Application Insights Track API path (D9, #151)"
grep -qiE 'alongside|additional transport|independent' "$FLAT" \
  || fail "doc must frame OTLP/HTTP as an additional transport alongside the Track API path (D9, #151)"

finish
