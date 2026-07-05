#!/usr/bin/env bash
# test_trace_export_backstop.sh — RED sensor pinning the BREADTH of the
# Gate-2 hardcoded secret-shape backstop in scripts/trace-export.sh AND the
# matching shapes in trace_redact (scripts/trace-lib.sh) for issue #113,
# feature trace-export-backstop-breadth.
#
# Contract under test (PINNED HERE as the executable spec):
#
#   The Gate-2 backstop is INDEPENDENT of trace_redact working (a no-op
#   redactor cannot blind it) and today catches gh[pousr]_ / github_pat_ /
#   AKIA... shapes. This feature widens BOTH the backstop and trace_redact
#   to additionally catch:
#     (a) InstrumentationKey=<guid> — the sink's OWN connection-string
#         self-leak (a run that echoes its App Insights key into a span
#         value must never be shipped back to that same sink).
#     (b) sk-* API-key shapes, ANCHORED as sk-ant-<20+> or sk-<20+> — never
#         a bare "sk-" (avoids false positives on prose / short tokens).
#
#   RED expectations (these currently SHIP — the sensor fails until #113
#   lands):
#     1. A span carrying InstrumentationKey=<a-guid> in an ALLOWLISTED field
#        (harness.warning) reaches the staged envelopes; the backstop must
#        REFUSE the export (non-zero exit, no dry-run file, no re-leak).
#     2. A span carrying sk-ant-<20+> / sk-<20+> in an allowlisted field
#        must likewise be REFUSED by the backstop, AND trace_redact must
#        mask the same shapes to [REDACTED].
#
#   FALSE-POSITIVE guard (must stay GREEN, before and after #113):
#     3. A legitimate value that merely contains "sk-" followed by few
#        chars (sk-1), or the literal word "InstrumentationKey" WITHOUT an
#        =<guid>, must NOT be dropped/refused — a clean trace with these
#        prose strings exports exit 0 and trace_redact leaves them intact.
#
# The backstop is exercised through a NO-OP trace_redact mutant (same
# technique as test_trace_export_redaction.sh leg C): with redaction
# blinded, only the hardcoded backstop can catch the InstrumentationKey /
# sk- shapes on the OUTPUT — proving the check is the backstop's own, not
# trace_redact's.
#
# All planted secrets are SYNTHETIC (fake GUIDs, fake sk- strings) per
# docs/evaluation/security-evals.md / dataset-governance.md — never a real
# credential.
#
# NOTE: this is a NEW file deliberately separate from the shared redaction
# sensors (test_trace_export_redaction.sh / test_trace_lib_redaction.sh) to
# avoid collisions with a parallel feature editing those.
#
# Exit codes: 0 backstop-breadth contract honored · 1 a contract obligation
# regressed (RED today for the InstrumentationKey / sk- legs).

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
  || hard_fail "jq is required to validate exporter backstop behavior"
[ -f "$EXPORTER" ] || hard_fail "scripts/trace-export.sh not found (${EXPORTER})"
[ -f "$TRACE_LIB" ] || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$VALIDATOR" ] || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
[ -f "$CONTRACT" ] || hard_fail "trace schema contract not found (${CONTRACT})"

# Pinned PATH with a tripwire curl: the gate must stop everything before any
# transport; any curl invocation in this sensor is a failure.
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

# --- Planted SYNTHETIC secrets (never real credentials) ------------------------
# A fake GUID for the InstrumentationKey self-leak, and fake sk- API-key
# shapes with 20+ trailing chars so the ANCHORED rule (not a bare sk-) fires.
FAKE_GUID='00000000-0000-4000-8000-0000feed1130'
IKEY_LEAK="InstrumentationKey=${FAKE_GUID}"
# Lowercase-prefix variant — a connection string can arrive case-shifted; the
# anchor must be case-insensitive so instrumentationkey=<guid> cannot slip past.
IKEY_LC_LEAK="instrumentationkey=${FAKE_GUID}"
SK_ANT_LEAK='sk-ant-api03-SYNTHETIC00abcdefghijklmnop0123456789'
SK_BARE_LEAK='sk-SYNTHETIC00abcdefghijklmnopqrstuvwxyz01'

# False-positive tripwires (legitimate content that must survive):
#   - "sk-1": the sk- prefix with too few chars to be a key.
#   - the literal word "InstrumentationKey" with NO =<guid>.
SK_INNOCENT='sk-1'
IKEY_WORD='see the InstrumentationKey note in the runbook'

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

# The backstop-breadth legs run through a NO-OP redactor so Gate 1's
# redaction audit (which reuses trace_redact) goes blind and the planted
# shape reaches the staged envelopes — only the INDEPENDENT hardcoded
# backstop can then refuse. Same technique as the redaction sensor leg C.
mk_repo_noop_redact() { # mk_repo_noop_redact <dir>
  local d="$1"
  mk_repo "$d"
  cat > "${d}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib: redaction is a no-op (a valid fixed point for ANY
# input), so ONLY the hardcoded Gate-2 backstop can catch leaks.
trace_redact() { cat; }
trace_warn() { printf 'trace-lib: warning: %s\n' "$*" >&2; }
trace_now_ms() { printf '0'; }
SH
}

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

FIX="${TMP_DIR}/fixture-repo"
mk_repo "$FIX"
NOOP="${TMP_DIR}/noop-repo"
mk_repo_noop_redact "$NOOP"

# Clean, schema-valid base trace (no secrets, unfinished so the validator's
# completeness pass is skipped).
CLEAN="${TMP_DIR}/clean.trace.jsonl"
cat > "$CLEAN" <<'JSONL'
{"schema_version":1,"timestamp":"2026-07-05T09:00:00Z","span":"lifecycle","harness.issue":113,"harness.version":"abc1234","span_id":"blc00001","harness.lifecycle_step":"preflight"}
{"schema_version":1,"timestamp":"2026-07-05T09:00:01Z","span":"tool","harness.issue":113,"harness.version":"abc1234","span_id":"btool001","gen_ai.tool.name":"git","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":50}
JSONL

# Leaky traces: each adds one span planting a shape in the ALLOWLISTED
# harness.warning field, so without a widened backstop it rides straight
# into an envelope's customDimensions.
mk_leaky() { # mk_leaky <out> <planted-value>
  local out="$1" val="$2"
  cp "$CLEAN" "$out"
  printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:04Z\",\"span\":\"tool\",\"harness.issue\":113,\"harness.version\":\"abc1234\",\"span_id\":\"bleak001\",\"gen_ai.tool.name\":\"gh\",\"harness.warning\":\"${val}\"}" >> "$out"
}

IKEY_TRACE="${TMP_DIR}/ikey.trace.jsonl"
IKEY_LC_TRACE="${TMP_DIR}/ikey-lc.trace.jsonl"
SK_ANT_TRACE="${TMP_DIR}/sk-ant.trace.jsonl"
SK_BARE_TRACE="${TMP_DIR}/sk-bare.trace.jsonl"
mk_leaky "$IKEY_TRACE" "$IKEY_LEAK"
mk_leaky "$IKEY_LC_TRACE" "$IKEY_LC_LEAK"
mk_leaky "$SK_ANT_TRACE" "$SK_ANT_LEAK"
mk_leaky "$SK_BARE_TRACE" "$SK_BARE_LEAK"

# ==============================================================================
# A. RED — InstrumentationKey=<guid> self-leak must trip the backstop.
#    Runs through the no-op redactor so only the hardcoded backstop can act.
# ==============================================================================
OUTA="${TMP_DIR}/a.envelopes.json"
rc=0
run_export "$NOOP" "${TMP_DIR}/a.out" TRACE_EXPORT_OTLP=1 -- "$IKEY_TRACE" --dry-run-to-file "$OUTA" || rc=$?
[ "$rc" != "0" ] \
  || fail "A: InstrumentationKey=<guid> self-leak reached the staged envelopes but the backstop shipped it (exit 0) — the backstop must additionally catch InstrumentationKey=<guid>"
if [ -e "$OUTA" ] && grep -qF -- "$FAKE_GUID" "$OUTA"; then
  fail "A: the backstop left a dry-run file leaking the InstrumentationKey GUID at ${OUTA} — exit-with-leak is forbidden"
fi
grep -qF -- "$FAKE_GUID" "${TMP_DIR}/a.out" \
  && fail "A: the failure message re-leaked the InstrumentationKey GUID on stdout/stderr (findings must never echo values)"

# A2. RED — the lowercase-prefix variant instrumentationkey=<guid> must ALSO trip
#     the backstop (case-insensitive anchor), and must never leak on refusal.
OUTA2="${TMP_DIR}/a2.envelopes.json"
rc=0
run_export "$NOOP" "${TMP_DIR}/a2.out" TRACE_EXPORT_OTLP=1 -- "$IKEY_LC_TRACE" --dry-run-to-file "$OUTA2" || rc=$?
[ "$rc" != "0" ] \
  || fail "A2: lowercase instrumentationkey=<guid> self-leak shipped (exit 0) — the backstop anchor must be case-insensitive"
if [ -e "$OUTA2" ] && grep -qF -- "$FAKE_GUID" "$OUTA2"; then
  fail "A2: the backstop left a dry-run file leaking the lowercase InstrumentationKey GUID at ${OUTA2}"
fi

# ==============================================================================
# B. RED — sk-ant-<20+> must trip the backstop AND trace_redact must mask it.
# ==============================================================================
OUTB="${TMP_DIR}/b.envelopes.json"
rc=0
run_export "$NOOP" "${TMP_DIR}/b.out" TRACE_EXPORT_OTLP=1 -- "$SK_ANT_TRACE" --dry-run-to-file "$OUTB" || rc=$?
[ "$rc" != "0" ] \
  || fail "B: sk-ant-<20+> API key reached the staged envelopes but the backstop shipped it (exit 0) — the backstop must catch anchored sk-ant-... / sk-<20+> shapes"
if [ -e "$OUTB" ] && grep -qF -- "$SK_ANT_LEAK" "$OUTB"; then
  fail "B: the backstop left a dry-run file leaking the sk-ant- key at ${OUTB} — exit-with-leak is forbidden"
fi

# ==============================================================================
# B'. RED — bare sk-<20+> (20+ trailing chars, no ant- infix) must also trip.
# ==============================================================================
OUTBP="${TMP_DIR}/bp.envelopes.json"
rc=0
run_export "$NOOP" "${TMP_DIR}/bp.out" TRACE_EXPORT_OTLP=1 -- "$SK_BARE_TRACE" --dry-run-to-file "$OUTBP" || rc=$?
[ "$rc" != "0" ] \
  || fail "B': sk-<20+> API key reached the staged envelopes but the backstop shipped it (exit 0) — the anchored sk-[A-Za-z0-9]{20,} rule must catch it"
if [ -e "$OUTBP" ] && grep -qF -- "$SK_BARE_LEAK" "$OUTBP"; then
  fail "B': the backstop left a dry-run file leaking the bare sk- key at ${OUTBP} — exit-with-leak is forbidden"
fi

# ==============================================================================
# B''. RED — trace_redact (the REAL library) must mask both sk- shapes.
#     Assert directly against the sourced filter, mirroring the redaction
#     sensor's approach.
# ==============================================================================
redact_masks() { # redact_masks <input> — true if [REDACTED] replaces the input verbatim
  local in="$1" out=""
  out="$(
    cd "$FIX"
    # shellcheck source=/dev/null
    source "./scripts/trace-lib.sh"
    printf '%s\n' "$in" | trace_redact
  )" || return 2
  # Masked iff the raw secret literal is gone from the redactor's output.
  ! printf '%s\n' "$out" | grep -qF -- "$in"
}

redact_masks "\"harness.warning\":\"${SK_ANT_LEAK}\"" \
  || fail "B'': trace_redact did not mask the sk-ant-<20+> shape — trace-lib.sh must add an anchored sk-ant-... / sk-[A-Za-z0-9]{20,} rule"
redact_masks "\"harness.warning\":\"${SK_BARE_LEAK}\"" \
  || fail "B'': trace_redact did not mask the bare sk-<20+> shape — trace-lib.sh must add the anchored sk-[A-Za-z0-9]{20,} rule"
redact_masks "\"harness.warning\":\"${IKEY_LEAK}\"" \
  || fail "B'': trace_redact did not mask the InstrumentationKey=<guid> shape — trace-lib.sh must add an InstrumentationKey=<guid> rule"

# ==============================================================================
# C. FALSE-POSITIVE guard (must stay GREEN before AND after #113): prose
#    containing "sk-1" and the literal word "InstrumentationKey" (no =<guid>)
#    must NOT be refused, and trace_redact must leave them intact.
# ==============================================================================
INNOCENT="${TMP_DIR}/innocent.trace.jsonl"
cp "$CLEAN" "$INNOCENT"
printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:05Z\",\"span\":\"tool\",\"harness.issue\":113,\"harness.version\":\"abc1234\",\"span_id\":\"bok00001\",\"gen_ai.tool.name\":\"git\",\"harness.warning\":\"${SK_INNOCENT} ${IKEY_WORD}\"}" >> "$INNOCENT"

OUTC="${TMP_DIR}/c.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/c.out" TRACE_EXPORT_OTLP=1 -- "$INNOCENT" --dry-run-to-file "$OUTC" || rc=$?
[ "$rc" = "0" ] \
  || fail "C: a legitimate value containing 'sk-1' and the bare word 'InstrumentationKey' (no =<guid>) must NOT be refused, got exit ${rc}: $(tr '\n' '|' < "${TMP_DIR}/c.out")"
[ -f "$OUTC" ] \
  || fail "C: the innocent trace must produce a dry-run envelope file (${OUTC})"

if redact_masks "sk-1 and the word InstrumentationKey in prose"; then
  fail "C: trace_redact wrongly masked legitimate 'sk-1' / bare-word 'InstrumentationKey' prose — the anchored rules must not fire on short sk- or on InstrumentationKey without =<guid>"
fi

# ==============================================================================
# D. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "D: the exporter invoked curl during a gated run — the gate must stop everything before transport: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export backstop-breadth contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export backstop-breadth contract honored\n'
