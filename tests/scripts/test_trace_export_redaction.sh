#!/usr/bin/env bash
# test_trace_export_redaction.sh — regression sensor for the fail-closed
# export gate in scripts/trace-export.sh (issue #112, feature
# trace-export-redaction-gate, plan Phase 2: Gate 1 + Gate 2).
#
# Contract under test (PINNED HERE as the executable spec; conductor-resolved
# fork: the gate runs on BOTH delivery paths — dry-run is NOT a debugging
# bypass; a leaking input exits 1 with NOTHING written anywhere):
#
#   Gate 1 — input gate (validate-trace reuse, plan D4: one redaction
#   policy, never a fork): a trace that validate-trace.sh would fail
#   (which includes its redaction_leak audit — a planted secret-shaped
#   token on any line) makes trace-export.sh exit 1 and write NOTHING:
#   no dry-run file, no shipped envelopes (the tripwire curl must never
#   run), fail-closed on the ship path too (gate precedes transport).
#
#   Gate 2 — output audit (sanitize-trace precedent, staged temp file):
#   the serialized envelope array is audited INDEPENDENTLY before leaving
#   staging — trace_redact fixed point PLUS a hardcoded secret-shape
#   backstop (ghp_/github_pat_/AKIA shapes) that does NOT depend on
#   trace_redact working. Mutant leg: with a NO-OP trace_redact sourced
#   from the exporter's script dir, Gate 1 goes blind and a secret riding
#   an ALLOWLISTED field (harness.warning) reaches the staged envelopes —
#   the backstop must still catch it: non-zero exit, no output file (and
#   never a file containing the raw secret). Exit 0 with a leak on disk
#   is the one forbidden outcome.
#
#   Broken redactor: with a trace-lib whose trace_redact FAILS at runtime,
#   the exporter fails closed — non-zero exit (1 or 2), nothing written.
#   "The auditor broke" must never degrade to "ship anyway".
#
#   No re-leak: no failing run may echo the planted secret to stdout or
#   stderr (validate-trace doctrine: findings never re-leak values).
#
#   Clean trace: passes both gates — exit 0, dry-run file written, and the
#   file (comments stripped) is itself a trace_redact fixed point.
#
# RED while redaction_gate() in scripts/trace-export.sh is the feature-1
# pass-through: the leaking-input run exits 0 and ships the secret into
# the dry-run file, which this sensor forbids.
#
# Exit codes: 0 gate contract honored · 1 a contract obligation regressed.

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
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required to validate exporter gate behavior"
[ -f "$EXPORTER" ] \
  || hard_fail "scripts/trace-export.sh not found (${EXPORTER}) — feature 1 (trace-export-mapping-core) must land before the gate"
[ -f "$TRACE_LIB" ] || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$VALIDATOR" ] || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
[ -f "$CONTRACT" ] || hard_fail "trace schema contract not found (${CONTRACT})"

# Pinned PATH with a tripwire curl: the gate must stop everything before
# any transport; any curl invocation in this sensor is a failure.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
CURL_MARKER="${TMP_DIR}/curl-was-called"
cat > "${BIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${CURL_MARKER}"
exit 7
SH
chmod +x "${BIN}/curl"

# Planted synthetic secret (never a real credential): a ghp_ shape that
# trace_redact masks and validate-trace's redaction_leak audit flags.
GHP="ghp_FAKEB0GATE0LEAK0SHAPE0ABCDEFGHIJKL"

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
  [ "${1:-}" = "--" ] && shift
  (cd "$repo" \
    && env -u TRACE_EXPORT_OTLP -u APPLICATIONINSIGHTS_CONNECTION_STRING \
       ${envkv[@]+"${envkv[@]}"} PATH="$BIN" \
       "./scripts/trace-export.sh" "$@") > "$rep" 2>&1
}

# Clean, schema-valid 4-span trace (no secrets, no home paths, unfinished
# so the validator's completeness pass is skipped).
CLEAN="${TMP_DIR}/clean.trace.jsonl"
cat > "$CLEAN" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-05T09:00:00Z","span":"lifecycle","harness.issue":112,"harness.version":"abc1234","span_id":"rlc00001","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-05T09:00:01Z","span":"tool","harness.issue":112,"harness.version":"abc1234","span_id":"rtool001","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":50}
{"schema_version":1,"timestamp":"2026-07-05T09:00:02Z","span":"agent","harness.issue":112,"harness.version":"abc1234","span_id":"ragent01","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-05T09:00:03Z","span":"model","harness.issue":112,"harness.version":"abc1234","span_id":"rmodel01","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":1000,"gen_ai.usage.output_tokens":200}
JSONL

# Leaking trace: the same spans plus one carrying the planted secret in an
# ALLOWLISTED field (harness.warning), so without the gate the secret would
# ride straight into an envelope's customDimensions.
LEAKY="${TMP_DIR}/leaky.trace.jsonl"
cp "$CLEAN" "$LEAKY"
printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:04Z\",\"span\":\"tool\",\"harness.issue\":112,\"harness.version\":\"abc1234\",\"span_id\":\"rleak001\",\"gen_ai.tool.name\":\"gh\",\"harness.warning\":\"${GHP}\"}" >> "$LEAKY"

# ==============================================================================
# A. Gate 1, dry-run path: leaking input → exit 1, NOTHING written
#    (conductor-resolved: dry-run is NOT a bypass — fail-closed everywhere).
# ==============================================================================
OUTA="${TMP_DIR}/a.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/a.out" TRACE_EXPORT_OTLP=1 -- "$LEAKY" --dry-run-to-file "$OUTA" || rc=$?
[ "$rc" = "1" ] \
  || fail "A: a leaking input trace must make the exporter exit 1 on the dry-run path too (fail-closed everywhere), got ${rc}"
[ ! -e "$OUTA" ] \
  || fail "A: leaking input — NOTHING may be written, but the dry-run file exists at ${OUTA}"
grep -qF -- "$GHP" "${TMP_DIR}/a.out" \
  && fail "A: the exporter re-leaked the planted secret on stdout/stderr (findings must never echo values)"

# ==============================================================================
# B. Gate 1, ship path: leaking input + connection string set → exit 1
#    BEFORE transport (gate precedes ship; the tripwire curl must not run).
# ==============================================================================
rc=0
run_export "$FIX" "${TMP_DIR}/b.out" TRACE_EXPORT_OTLP=1 \
  "APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=00000000-0000-4000-8000-000000000112;IngestionEndpoint=https://synthetic.in.applicationinsights.azure.invalid/" \
  -- "$LEAKY" || rc=$?
[ "$rc" = "1" ] \
  || fail "B: leaking input on the ship path must exit 1 from the gate (before any transport), got ${rc}"
grep -qF -- "$GHP" "${TMP_DIR}/b.out" \
  && fail "B: the ship-path gate failure re-leaked the planted secret on stdout/stderr"

# ==============================================================================
# C. Gate 2 backstop, mutant leg: NO-OP trace_redact blinds Gate 1 (the
#    validator's redaction_leak audit reuses trace_redact), so the secret
#    reaches the staged envelopes — the INDEPENDENT hardcoded secret-shape
#    backstop must catch it on the OUTPUT: non-zero exit, no leaking file.
# ==============================================================================
MUT="${TMP_DIR}/mutant-noop"
mk_repo "$MUT"
cat > "${MUT}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib for the backstop test: redaction is a no-op (a valid
# fixed point for ANY input), so only a hardcoded backstop can catch leaks.
trace_redact() { cat; }
trace_warn() { printf 'trace-lib: warning: %s\n' "$*" >&2; }
trace_now_ms() { printf '0'; }
SH

OUTC="${TMP_DIR}/c.envelopes.json"
rc=0
run_export "$MUT" "${TMP_DIR}/c.out" TRACE_EXPORT_OTLP=1 -- "$LEAKY" --dry-run-to-file "$OUTC" || rc=$?
[ "$rc" != "0" ] \
  || fail "C: with a no-op redactor the secret reaches the staged envelopes — the hardcoded output backstop must exit non-zero, got exit 0"
if [ -e "$OUTC" ] && grep -qF -- "$GHP" "$OUTC"; then
  fail "C: the backstop left a leaking envelope file on disk (raw ghp_ shape at ${OUTC}) — exit-nonzero-with-leak is the forbidden outcome"
fi
grep -qF -- "$GHP" "${TMP_DIR}/c.out" \
  && fail "C: the backstop failure re-leaked the planted secret on stdout/stderr"

# ==============================================================================
# D. Broken redactor: trace_redact FAILS at runtime → fail closed (exit 1
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

OUTD="${TMP_DIR}/d.envelopes.json"
rc=0
run_export "$BRK" "${TMP_DIR}/d.out" TRACE_EXPORT_OTLP=1 -- "$CLEAN" --dry-run-to-file "$OUTD" || rc=$?
if [ "$rc" != "1" ] && [ "$rc" != "2" ]; then
  fail "D: a failing trace_redact must fail the export closed (exit 1 or 2), got ${rc}"
fi
[ ! -e "$OUTD" ] \
  || fail "D: broken-redactor run must write NOTHING — dry-run file exists at ${OUTD}"

# ==============================================================================
# E. Clean trace: passes both gates — exit 0, dry-run file written, and the
#    output (comments stripped) is itself a trace_redact fixed point.
# ==============================================================================
OUTE="${TMP_DIR}/e.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/e.out" TRACE_EXPORT_OTLP=1 -- "$CLEAN" --dry-run-to-file "$OUTE" || rc=$?
[ "$rc" = "0" ] \
  || fail "E: a clean trace must pass both gates and exit 0, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/e.out")"
if [ -f "$OUTE" ]; then
  grep -v '^//' "$OUTE" | jq -e 'type == "array" and length == 4' > /dev/null 2>&1 \
    || fail "E: clean-trace dry-run must still produce the 4-envelope array"
  stripped="${TMP_DIR}/e.stripped"
  grep -v '^//' "$OUTE" > "$stripped"
  redacted="${TMP_DIR}/e.redacted"
  (
    cd "$FIX"
    # shellcheck source=/dev/null
    source "./scripts/trace-lib.sh"
    trace_redact < "$stripped" > "$redacted"
  ) || fail "E: running trace_redact over the clean output failed"
  if [ -f "$redacted" ] && ! cmp -s "$stripped" "$redacted"; then
    fail "E: the clean dry-run output is not a trace_redact fixed point — a secret-shaped token is in the envelopes"
  fi
else
  fail "E: clean-trace dry-run did not write the envelope file (${OUTE})"
fi

# ==============================================================================
# F. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "F: the exporter invoked curl during a gated run — the gate must stop everything before transport: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export redaction-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export redaction-gate contract honored\n'
