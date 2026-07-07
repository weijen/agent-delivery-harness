#!/usr/bin/env bash
# test_trace_export_otlp_redaction.sh — RED sensor pinning that the
# fail-closed export gate (redaction_gate() in scripts/trace-export.sh) also
# guards the OTLP/HTTP+JSON dry-run seam (issue #151, feature
# otlp-http-redaction-gate).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/trace-export.sh <trace> --dry-run-otlp-to-file <out.json>
#
#   The OTLP dry-run seam (feature otlp-http-mapping) currently projects the
#   census'd spans and mv's the staged resourceSpans body into place WITHOUT
#   running redaction_gate() — the SAME fail-closed gate the App-Insights
#   --dry-run-to-file path already runs before anything leaves staging. This
#   feature makes the identical gate apply to the OTLP staged body. Because
#   the gate is not yet wired into the OTLP branch, the refusal legs (A–C)
#   currently SUCCEED (write out.json / exit 0) — that is the RED.
#
#   Gate obligations mirrored onto the OTLP seam (dry-run is NOT a bypass —
#   plan D4 one redaction policy, never a fork):
#
#     A. Gate 1 input redaction leak (validate-trace reuse): a span carrying
#        a FULL-LENGTH secret-shaped token (a >=20-char ghp_) in an
#        ALLOWLISTED field makes the OTLP dry-run EXIT 1 and write NO out.json
#        (fail-closed before the mapping ships anything). No re-leak of the
#        planted value to stdout/stderr (findings never echo values).
#
#     B. Gate 2b hardcoded secret-shape backstop on the OTLP body: with a
#        NO-OP trace_redact sourced from the exporter's script dir, Gate 1's
#        redaction audit (which reuses trace_redact) goes blind and the secret
#        rides an allowlisted field into the staged OTLP body — the INDEPENDENT
#        hardcoded backstop (ghp_/github_pat_/AKIA) must still REFUSE: non-zero
#        exit, no out.json (and never a file carrying the raw secret).
#
#     C. Broken/failing trace_redact fails closed: a trace-lib whose
#        trace_redact ERRORS at runtime + an otherwise-clean fixture must make
#        the OTLP dry-run refuse (exit 1 or 2), nothing written. "The auditor
#        broke" is never "ship anyway".
#
#     D. Clean fixture positive control (proves the sensor is not trivially
#        always-red): a fully clean, allowlist-only fixture passes the gate —
#        exit 0, out.json written, a valid { resourceSpans: [...] } payload.
#
#   Zero-network: no run in this sensor may ever invoke curl (a tripwire curl
#   on the pinned PATH records any invocation; any invocation is a failure).
#
# All planted secrets are SYNTHETIC (never real credentials) per
# docs/evaluation/security-evals.md / dataset-governance.md.
#
# RED while redaction_gate() does not run on the --dry-run-otlp-to-file
# branch: legs A–C wrongly write out.json / exit 0; leg D already passes.
#
# Exit codes: 0 OTLP gate contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="${ROOT}/scripts/trace-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Prerequisites -----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  hard_fail "jq is required to validate exporter OTLP gate behavior"
fi
if [ ! -f "$EXPORTER" ]; then
  hard_fail "scripts/trace-export.sh not found (${EXPORTER})"
fi
if [ ! -f "$TRACE_LIB" ]; then
  hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
fi
if [ ! -f "$ISSUE_LIB" ]; then
  hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
fi
if [ ! -f "$VALIDATOR" ]; then
  hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
fi
if [ ! -f "$CONTRACT" ]; then
  hard_fail "trace schema contract not found (${CONTRACT})"
fi

# Pinned PATH with a tripwire curl: the OTLP dry-run seam is zero-network by
# contract (it writes a file, never ships); any curl invocation is a failure.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp; do
  p="$(command -v "$t" || true)"
  if [ -n "$p" ]; then
    ln -sf "$p" "${BIN}/${t}"
  fi
done
CURL_MARKER="${TMP_DIR}/curl-was-called"
cat > "${BIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${CURL_MARKER}"
exit 7
SH
chmod +x "${BIN}/curl"

# Planted SYNTHETIC secret (never a real credential): a full-length ghp_
# shape (>=20 chars after the prefix) that trace_redact masks and
# validate-trace's redaction_leak audit flags.
GHP="ghp_FAKEB0OTLP0GATE0LEAK0ABCDEFGHIJKL"

mk_repo() { # mk_repo <dir> — harness-shaped repo with the real scripts
  local d="$1"
  mkdir -p "${d}/scripts" "${d}/docs/evaluation"
  cp "$EXPORTER" "${d}/scripts/trace-export.sh"
  cp "$TRACE_LIB" "${d}/scripts/trace-lib.sh"
  cp "$ISSUE_LIB" "${d}/scripts/issue-lib.sh"
  cp "$VALIDATOR" "${d}/scripts/validate-trace.sh"
  cp "$CONTRACT" "${d}/docs/evaluation/trace-schema.v1.json"
  chmod +x "${d}/scripts/trace-export.sh" "${d}/scripts/validate-trace.sh"
  git -C "$d" init -q -b main
  git -C "$d" config user.name "Harness Test"
  git -C "$d" config user.email "harness-test@example.invalid"
}

FIX="${TMP_DIR}/fixture-repo"
mk_repo "$FIX"

run_export() { # run_export <repo> <report-file> [ENVKV...] -- <args...>
  local repo="$1" rep="$2"; shift 2
  local -a envkv=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envkv+=("$1"); shift
  done
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  (cd "$repo" \
    && env -u TRACE_EXPORT_OTLP -u APPLICATIONINSIGHTS_CONNECTION_STRING \
       ${envkv[@]+"${envkv[@]}"} PATH="$BIN" \
       "./scripts/trace-export.sh" "$@") > "$rep" 2>&1
}

# Clean, schema-valid 4-span trace (no secrets, only allowlisted fields,
# unfinished so the validator's completeness pass is skipped).
CLEAN="${TMP_DIR}/clean.trace.jsonl"
cat > "$CLEAN" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-05T09:00:00Z","span":"lifecycle","harness.issue":151,"harness.version":"abc1234","span_id":"otlc0001","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-05T09:00:01Z","span":"tool","harness.issue":151,"harness.version":"abc1234","span_id":"otto0001","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":50}
{"schema_version":1,"timestamp":"2026-07-05T09:00:02Z","span":"agent","harness.issue":151,"harness.version":"abc1234","span_id":"otag0001","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-05T09:00:03Z","span":"model","harness.issue":151,"harness.version":"abc1234","span_id":"otmo0001","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":1000,"gen_ai.usage.output_tokens":200}
JSONL

# Leaking trace: the clean spans plus one carrying the planted full-length
# secret in an ALLOWLISTED field (harness.warning), so without the gate the
# secret would ride straight into the OTLP staged body's attributes.
LEAKY="${TMP_DIR}/leaky.trace.jsonl"
cp "$CLEAN" "$LEAKY"
printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:04Z\",\"span\":\"tool\",\"harness.issue\":151,\"harness.version\":\"abc1234\",\"span_id\":\"otlk0001\",\"gen_ai.tool.name\":\"gh\",\"harness.warning\":\"${GHP}\"}" >> "$LEAKY"

# ==============================================================================
# A. Gate 1, OTLP dry-run path: leaking input → exit 1, NO out.json
#    (dry-run is NOT a bypass — the OTLP seam must fail closed too).
# ==============================================================================
OUTA="${TMP_DIR}/a.otlp.json"
rc=0
run_export "$FIX" "${TMP_DIR}/a.out" TRACE_EXPORT_OTLP=1 -- "$LEAKY" --dry-run-otlp-to-file "$OUTA" || rc=$?
if [ "$rc" != "1" ]; then
  fail "A: a leaking input trace must make the OTLP dry-run exit 1 (Gate 1 redaction leak, fail-closed everywhere), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/a.out")"
fi
if [ -e "$OUTA" ]; then
  fail "A: leaking input — NOTHING may be written, but the OTLP dry-run file exists at ${OUTA}"
fi
if grep -qF -- "$GHP" "${TMP_DIR}/a.out"; then
  fail "A: the OTLP dry-run re-leaked the planted secret on stdout/stderr (findings must never echo values)"
fi

# ==============================================================================
# B. Gate 2b backstop, mutant leg: NO-OP trace_redact blinds Gate 1 (the
#    validator's redaction_leak audit reuses trace_redact), so the secret
#    reaches the staged OTLP body — the INDEPENDENT hardcoded secret-shape
#    backstop must catch it on the OUTPUT: non-zero exit, no leaking file.
# ==============================================================================
MUT="${TMP_DIR}/mutant-noop"
mk_repo "$MUT"
cat > "${MUT}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib for the OTLP backstop test: redaction is a no-op (a valid
# fixed point for ANY input), so only a hardcoded backstop can catch leaks.
trace_redact() { cat; }
trace_warn() { printf 'trace-lib: warning: %s\n' "$*" >&2; }
trace_now_ms() { printf '0'; }
SH

OUTB="${TMP_DIR}/b.otlp.json"
rc=0
run_export "$MUT" "${TMP_DIR}/b.out" TRACE_EXPORT_OTLP=1 -- "$LEAKY" --dry-run-otlp-to-file "$OUTB" || rc=$?
if [ "$rc" = "0" ]; then
  fail "B: with a no-op redactor the secret reaches the staged OTLP body — the hardcoded backstop must exit non-zero, got exit 0: $(tr '\n' '|' < "${TMP_DIR}/b.out")"
fi
if [ -e "$OUTB" ] && grep -qF -- "$GHP" "$OUTB"; then
  fail "B: the backstop left a leaking OTLP file on disk (raw ghp_ shape at ${OUTB}) — exit-nonzero-with-leak is the forbidden outcome"
fi
if grep -qF -- "$GHP" "${TMP_DIR}/b.out"; then
  fail "B: the backstop failure re-leaked the planted secret on stdout/stderr"
fi

# ==============================================================================
# C. Broken redactor: trace_redact FAILS at runtime → fail closed (exit 1
#    or 2), nothing written. 'The auditor broke' never means 'ship anyway'.
# ==============================================================================
BRK="${TMP_DIR}/mutant-broken"
mk_repo "$BRK"
cat > "${BRK}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib for the fail-closed test: the redactor itself errors.
trace_redact() { return 1; }
trace_warn() { printf 'trace-lib: warning: %s\n' "$*" >&2; }
trace_now_ms() { printf '0'; }
SH

OUTC="${TMP_DIR}/c.otlp.json"
rc=0
run_export "$BRK" "${TMP_DIR}/c.out" TRACE_EXPORT_OTLP=1 -- "$CLEAN" --dry-run-otlp-to-file "$OUTC" || rc=$?
if [ "$rc" != "1" ] && [ "$rc" != "2" ]; then
  fail "C: a failing trace_redact must fail the OTLP dry-run closed (exit 1 or 2), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/c.out")"
fi
if [ -e "$OUTC" ]; then
  fail "C: broken-redactor OTLP run must write NOTHING — dry-run file exists at ${OUTC}"
fi

# ==============================================================================
# D. Clean fixture positive control: passes the gate — exit 0, out.json
#    written, a valid { resourceSpans: [...] } payload. (Proves the sensor is
#    not trivially always-red.)
# ==============================================================================
OUTD="${TMP_DIR}/d.otlp.json"
rc=0
run_export "$FIX" "${TMP_DIR}/d.out" TRACE_EXPORT_OTLP=1 -- "$CLEAN" --dry-run-otlp-to-file "$OUTD" || rc=$?
if [ "$rc" != "0" ]; then
  fail "D: a clean fixture must pass the OTLP gate and exit 0, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/d.out")"
fi
if [ -f "$OUTD" ]; then
  if ! grep -v '^//' "$OUTD" | jq -e '.resourceSpans | type == "array" and length >= 1' > /dev/null 2>&1; then
    fail "D: clean-fixture OTLP dry-run must produce a valid { resourceSpans: [...] } payload"
  fi
else
  fail "D: clean-fixture OTLP dry-run did not write the output file (${OUTD})"
fi

# ==============================================================================
# E. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "E: the exporter invoked curl during a gated OTLP run — the gate must stop everything before transport: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export OTLP redaction-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export OTLP redaction-gate contract honored\n'
