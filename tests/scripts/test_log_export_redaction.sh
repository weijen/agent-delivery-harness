#!/usr/bin/env bash
# test_log_export_redaction.sh — regression sensor for the fail-closed
# LOG export gate in scripts/log-export.sh (issue #220, feature
# log-export-redaction-gate, plan Phase 6). The log-stream analogue of the
# span-stream gate: lifted from tests/scripts/test_trace_export_redaction.sh
# and tests/scripts/test_trace_export_value_caps.sh, adapted for the
# higher-leakage detail stream (message/payload free text).
#
# Contract under test (PINNED HERE as the executable spec). The gate runs on
# the STAGED log envelopes/body BEFORE anything is written, on BOTH dry-run
# seams (--dry-run-otlp-logs-to-file AND --dry-run-logs-to-file, LOG_EXPORT_OTLP=1),
# fail-closed, all-or-nothing (nothing written on ANY violation, exit non-zero):
#
#   1. OVER-CAP projected string value → REFUSE. Every projected string value
#      (a message, or an allowlisted structured property → customDimensions)
#      is capped: max 256 chars (256 ships, 257 refuses) AND printable charset
#      only (a C0/C1 control byte is a violation). On any violation the WHOLE
#      ship aborts — exit non-zero, NOTHING written; never silently truncated
#      nor stripped. The offending key is named; its value never echoed.
#
#   2. SECRET-SHAPED value SURVIVING → REFUSE (hardcoded backstop). A record
#      carrying a well-known secret shape (e.g. a ghp_ token long enough to
#      trip TRACE_SECRET_SHAPE_RE) that would survive into the staged
#      envelopes is caught by a hardcoded secret-shape backstop that is
#      INDEPENDENT of trace_redact — a no-op/broken redactor cannot blind it:
#      exit non-zero, no leaking file, and the secret is never re-echoed.
#
#   3. INVALID JSONL → REFUSE (fail-closed, all-or-nothing). Per plan Phase 6
#      ("an invalid JSONL line each abort the whole ship"), a malformed JSONL
#      line reaching the projector is a DISQUALIFYING abort for the log stream:
#      exit non-zero, nothing written. This deliberately TIGHTENS the mapper's
#      pre-gate skip-and-count into fail-closed refusal, because the log stream
#      is the higher-leakage detail stream (a truncated line may be a bisected
#      secret) — there is no log validator, so the projector cannot prove a
#      malformed line clean and must refuse.
#
#   4. REDACT-BEFORE-CAP fixed point. A value trace_redact would rewrite must
#      be redacted BEFORE the cap is measured (schema log-schema.v1.json:
#      "redact, then cap"), so redaction cannot be defeated by ordering. A
#      long (>256-char) secret-shaped message must therefore SHIP redacted to
#      [REDACTED] (short, in-cap) — NOT refuse for being over-cap — and the
#      staged output must be a trace_redact FIXED POINT (no raw secret shape).
#
#   5. CLEAN input passes. A well-formed log.jsonl with in-cap, non-secret,
#      allowlisted values ships: exit 0, the dry-run file is written, the
#      allowlisted values survive UNCHANGED, and the output (comments
#      stripped) is itself a trace_redact fixed point.
#
#   Zero-network: a fake curl on the pinned PATH records any invocation; ANY
#   invocation is a FAILURE (the dry-run seams never ship, so never touch curl).
#
# RED while scripts/log-export.sh has no log_redaction_gate(): today the
# over-cap / control-byte / secret-shaped / invalid-JSONL mutations all reach
# the dry-run file (it is created; the secret rides raw), and the redact-
# before-cap output is not a fixed point — every refusal / fixed-point
# assertion here FAILS. The CLEAN and 256-boundary GREEN legs already ship
# today and stay green.
#
# Exit codes: 0 log-gate contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="${ROOT}/scripts/log-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
LOG_CONTRACT="${ROOT}/docs/evaluation/log-schema.v1.json"
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
  || hard_fail "jq is required to validate the log export gate"
[ -f "$EXPORTER" ] \
  || hard_fail "scripts/log-export.sh not found (${EXPORTER}) — feature log-export-mapping must land before the gate"
[ -f "$TRACE_LIB" ] || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$LOG_CONTRACT" ] || hard_fail "log schema contract not found (${LOG_CONTRACT})"

# Pinned PATH with a tripwire curl: the gate must stop everything before any
# transport; any curl invocation in this sensor is a failure. python3/uv are
# DELIBERATELY absent so the engine resolves to jq deterministically.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  seq date dirname basename mkdir rm cp mv od cmp touch mktemp; do
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
# trace_redact masks and TRACE_SECRET_SHAPE_RE flags.
GHP="ghp_FAKEB0GATE0LEAK0SHAPE0ABCDEFGHIJKL"

mk_repo() { # mk_repo <dir> — harness-shaped repo with the real scripts
  local d="$1"
  mkdir -p "${d}/scripts" "${d}/docs/evaluation"
  cp "$EXPORTER" "${d}/scripts/log-export.sh"
  cp "$TRACE_LIB" "${d}/scripts/trace-lib.sh"
  cp "$ISSUE_LIB" "${d}/scripts/issue-lib.sh"
  cp "$LOG_CONTRACT" "${d}/docs/evaluation/log-schema.v1.json"
  chmod +x "${d}/scripts/log-export.sh"
  git -C "$d" init -q -b main
  git -C "$d" config user.name "Harness Test"
  git -C "$d" config user.email "harness-test@example.invalid"
}

FIX="${TMP_DIR}/fixture-repo"
mk_repo "$FIX"

run_export() { # run_export <repo> <report-file> -- <args...>
  local repo="$1" rep="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  (cd "$repo" \
    && env -u APPLICATIONINSIGHTS_CONNECTION_STRING \
       LOG_EXPORT_OTLP=1 PATH="$BIN" \
       "./scripts/log-export.sh" "$@") > "$rep" 2>&1
}

# repeat_x <n> — <n> literal 'x' bytes (printable ASCII filler, never a secret).
repeat_x() {
  local n="$1"
  printf 'x%.0s' $(seq 1 "$n")
}
V256="$(repeat_x 256)"   # exactly the 256 boundary (OK)
V257="$(repeat_x 257)"   # one over (must refuse)
V300="$(repeat_x 300)"   # comfortably over (must refuse)

# repeat_A <n> — <n> literal 'A' bytes, the token body of a long ghp_ secret.
repeat_A() {
  local n="$1"
  printf 'A%.0s' $(seq 1 "$n")
}

# clean_line <span_id> <message> — a schema-v1 info log record for issue 220.
clean_line() {
  printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:00Z\",\"level\":\"info\",\"harness.issue\":220,\"message\":\"$2\",\"span_id\":\"$1\"}"
}

# assert_refuses — run <input> through BOTH dry-run seams and require each to
# refuse (exit non-zero) with NOTHING written, and never re-leak the secret.
assert_refuses() { # assert_refuses <label> <input> [secret-needle]
  local label="$1" input="$2" needle="${3:-}" seam flag out rep rc
  for seam in otlp appinsights; do
    if [ "$seam" = "otlp" ]; then flag="--dry-run-otlp-logs-to-file"; else flag="--dry-run-logs-to-file"; fi
    out="${TMP_DIR}/${label}.${seam}.out.json"
    rep="${TMP_DIR}/${label}.${seam}.rep"
    rc=0
    run_export "$FIX" "$rep" -- "$input" "$flag" "$out" || rc=$?
    [ "$rc" != "0" ] \
      || fail "${label} [${seam}]: the gate must REFUSE (exit non-zero, all-or-nothing), got exit 0"
    [ ! -e "$out" ] \
      || fail "${label} [${seam}]: NOTHING may be written on a gate violation, but the dry-run file exists at ${out}"
    if [ -n "$needle" ]; then
      { grep -qF -- "$needle" "$rep" \
        && fail "${label} [${seam}]: the gate failure re-leaked the planted secret on stdout/stderr"; } || true
      if [ -e "$out" ]; then
        { grep -qF -- "$needle" "$out" \
          && fail "${label} [${seam}]: a leaking file was left on disk containing the raw secret (exit-nonzero-with-leak is forbidden)"; } || true
      fi
    fi
  done
}

# --- Fixtures ----------------------------------------------------------------
# CLEAN: three well-formed, in-cap, non-secret records.
CLEAN="${TMP_DIR}/clean.log.jsonl"
{
  clean_line "aaaaaaaaaaaaaaaa" "preflight ok"
  printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:01Z\",\"level\":\"info\",\"harness.issue\":220,\"message\":\"tool invoked\",\"span_id\":\"bbbbbbbbbbbbbbbb\",\"gen_ai.tool.name\":\"git\",\"harness.warning\":\"disk almost full\"}"
  printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:02Z\",\"level\":\"error\",\"harness.issue\":220,\"message\":\"step failed\"}"
} > "$CLEAN"

# 256-boundary GREEN: an allowlisted property (harness.warning) of EXACTLY
# 256 printable chars — inclusive cap, must still ship UNCHANGED.
OK256="${TMP_DIR}/ok256.log.jsonl"
printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:00Z\",\"level\":\"info\",\"harness.issue\":220,\"message\":\"cap edge\",\"span_id\":\"cccccccccccccccc\",\"harness.warning\":\"${V256}\"}" > "$OK256"

# 257-boundary RED: one char over the cap on an allowlisted property.
OVER257="${TMP_DIR}/over257.log.jsonl"
printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:00Z\",\"level\":\"info\",\"harness.issue\":220,\"message\":\"cap edge\",\"span_id\":\"dddddddddddddddd\",\"harness.warning\":\"${V257}\"}" > "$OVER257"

# Over-long RED: a 300-char allowlisted property → refuse (never truncate).
LONG="${TMP_DIR}/long.log.jsonl"
printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:00Z\",\"level\":\"info\",\"harness.issue\":220,\"message\":\"cap edge\",\"span_id\":\"eeeeeeeeeeeeeeee\",\"harness.warning\":\"${V300}\"}" > "$LONG"

# Control-byte RED: a raw 0x07 (BEL) inside an allowlisted string value
# (gen_ai.tool.name), embedded literally via jq implode.
CTRL="${TMP_DIR}/ctrl.log.jsonl"
jq -cn \
  '{log_schema_version:1,timestamp:"2026-07-10T10:00:00Z",level:"info","harness.issue":220,message:"ctrl edge",span_id:"ffffffffffffffff","gen_ai.tool.name":("git"+([7]|implode)+"hook")}' \
  > "$CTRL"

# Secret-shaped message RED: a ghp_ token in the free-text message that would
# survive into the staged envelopes (the hardcoded backstop must catch it).
SECRET="${TMP_DIR}/secret.log.jsonl"
printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:00Z\",\"level\":\"warn\",\"harness.issue\":220,\"message\":\"pushed with ${GHP} oops\",\"span_id\":\"1111111111111111\"}" > "$SECRET"

# Invalid-JSONL RED: a clean record plus a malformed line reaching the projector.
BADJSON="${TMP_DIR}/badjson.log.jsonl"
{
  clean_line "2222222222222222" "before the bad line"
  printf '%s\n' '{"log_schema_version":1,"timestamp":"2026-07-10T10:00:01Z"  BROKEN not json'
} > "$BADJSON"

# Redact-before-cap RED: a LONG (>256) secret-shaped message. Redact-before-cap
# masks it to [REDACTED] (short, in-cap) so it SHIPS redacted; a cap-before-
# redact ordering would wrongly refuse it as over-cap.
LONGSECRET="${TMP_DIR}/longsecret.log.jsonl"
GHP_LONG="ghp_$(repeat_A 300)"
printf '%s\n' "{\"log_schema_version\":1,\"timestamp\":\"2026-07-10T10:00:00Z\",\"level\":\"warn\",\"harness.issue\":220,\"message\":\"${GHP_LONG}\",\"span_id\":\"3333333333333333\"}" > "$LONGSECRET"

# ==============================================================================
# A. Value caps — over-cap / control-byte allowlisted values REFUSE on both seams.
# ==============================================================================
assert_refuses "over257" "$OVER257"
assert_refuses "long300" "$LONG"
assert_refuses "ctrlbyte" "$CTRL"
# Belt: if a file were somehow written, the over-long value must not have been
# silently truncated into it (truncation is a forbidden degrade path).
for seam in otlp appinsights; do
  o="${TMP_DIR}/long300.${seam}.out.json"
  { [ -e "$o" ] && grep -qF -- "$V300" "$o" \
    && fail "A [${seam}]: the over-long value reached the envelopes — it shipped instead of refusing"; } || true
done

# ==============================================================================
# B. Secret-shape backstop is INDEPENDENT of trace_redact: a no-op redactor
#    cannot blind it. There is no log validator, so a secret-shaped MESSAGE is
#    caught by trace_redact when it works (leg E ships it redacted); the
#    hardcoded backstop is the belt for when redaction is a no-op. With a no-op
#    trace_redact sourced from the exporter's script dir the secret reaches the
#    staged envelopes — the backstop must still REFUSE (exit non-zero, no
#    leaking file) on BOTH seams. (Contract point 2: "the backstop must catch
#    it even if trace_redact were a no-op.")
# ==============================================================================
MUT="${TMP_DIR}/mutant-noop"
mk_repo "$MUT"
cat > "${MUT}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib: redaction is a no-op (a valid fixed point for ANY input),
# so only a hardcoded backstop can catch a surviving secret.
trace_redact() { cat; }
trace_warn() { printf 'trace-lib: warning: %s\n' "$*" >&2; }
trace_now_ms() { printf '0'; }
SH
for seam in otlp appinsights; do
  if [ "$seam" = "otlp" ]; then flag="--dry-run-otlp-logs-to-file"; else flag="--dry-run-logs-to-file"; fi
  OUTB2="${TMP_DIR}/b2.${seam}.out.json"
  rc=0
  run_export "$MUT" "${TMP_DIR}/b2.${seam}.rep" -- "$SECRET" "$flag" "$OUTB2" || rc=$?
  [ "$rc" != "0" ] \
    || fail "B2 [${seam}]: with a no-op redactor the secret reaches staging — the hardcoded backstop must exit non-zero, got exit 0"
  if [ -e "$OUTB2" ] && grep -qF -- "$GHP" "$OUTB2"; then
    fail "B2 [${seam}]: the backstop left a leaking envelope file on disk (raw ghp_ at ${OUTB2}) — the forbidden outcome"
  fi
done

# ==============================================================================
# C. Broken redactor — trace_redact FAILS at runtime → fail closed (non-zero),
#    nothing written. "The auditor broke" never means "ship anyway".
# ==============================================================================
BRK="${TMP_DIR}/mutant-broken"
mk_repo "$BRK"
cat > "${BRK}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib: the redactor itself errors at runtime.
trace_redact() { return 1; }
trace_warn() { printf 'trace-lib: warning: %s\n' "$*" >&2; }
trace_now_ms() { printf '0'; }
SH
for seam in otlp appinsights; do
  if [ "$seam" = "otlp" ]; then flag="--dry-run-otlp-logs-to-file"; else flag="--dry-run-logs-to-file"; fi
  OUTC="${TMP_DIR}/c.${seam}.out.json"
  rc=0
  run_export "$BRK" "${TMP_DIR}/c.${seam}.rep" -- "$CLEAN" "$flag" "$OUTC" || rc=$?
  { [ "$rc" = "1" ] || [ "$rc" = "2" ]; } \
    || fail "C [${seam}]: a failing trace_redact must fail closed (exit 1 or 2), got ${rc}"
  [ ! -e "$OUTC" ] \
    || fail "C [${seam}]: broken-redactor run must write NOTHING — dry-run file exists at ${OUTC}"
done

# ==============================================================================
# D. Invalid JSONL — a malformed line reaching the projector aborts the whole
#    ship (fail-closed, all-or-nothing) on both seams. RED today: the mapper
#    skip-and-counts and ships the clean records.
# ==============================================================================
assert_refuses "badjson" "$BADJSON"

# ==============================================================================
# E. Redact-before-cap fixed point — a >256-char secret-shaped MESSAGE must be
#    redacted to [REDACTED] BEFORE the cap is measured, so it SHIPS redacted
#    (exit 0), the raw token is byte-absent, and the output is a trace_redact
#    fixed point. RED today: the raw ghp_ rides into the file (not a fixed
#    point). A cap-before-redact ordering would wrongly refuse (exit 0 pins it).
# ==============================================================================
for seam in otlp appinsights; do
  if [ "$seam" = "otlp" ]; then flag="--dry-run-otlp-logs-to-file"; else flag="--dry-run-logs-to-file"; fi
  OUTE="${TMP_DIR}/e.${seam}.out.json"
  rc=0
  run_export "$FIX" "${TMP_DIR}/e.${seam}.rep" -- "$LONGSECRET" "$flag" "$OUTE" || rc=$?
  [ "$rc" = "0" ] \
    || fail "E [${seam}]: redact-before-cap must SHIP the redacted long secret (exit 0, cap measured AFTER redaction), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/e.${seam}.rep")"
  if [ -f "$OUTE" ]; then
    { grep -qF -- "$GHP_LONG" "$OUTE" \
      && fail "E [${seam}]: the raw secret-shaped token rode into the staged output — redaction did not run before the cap"; } || true
    stripped="${TMP_DIR}/e.${seam}.stripped"
    redacted="${TMP_DIR}/e.${seam}.redacted"
    grep -v '^//' "$OUTE" > "$stripped"
    (
      cd "$FIX"
      # shellcheck source=/dev/null
      source "./scripts/trace-lib.sh"
      trace_redact < "$stripped" > "$redacted"
    ) || fail "E [${seam}]: running trace_redact over the output failed"
    if [ -f "$redacted" ] && ! cmp -s "$stripped" "$redacted"; then
      fail "E [${seam}]: the dry-run output is not a trace_redact fixed point — secret-shaped content would ship"
    fi
  else
    fail "E [${seam}]: redact-before-cap run did not write the output file (${OUTE})"
  fi
done

# ==============================================================================
# F. 256-boundary GREEN — an allowlisted value of EXACTLY 256 printable chars
#    is at the inclusive cap and must ship UNCHANGED (exit 0).
# ==============================================================================
OUT256="${TMP_DIR}/ok256.out.json"
rc=0
run_export "$FIX" "${TMP_DIR}/ok256.rep" -- "$OK256" --dry-run-logs-to-file "$OUT256" || rc=$?
[ "$rc" = "0" ] \
  || fail "F: a 256-char printable allowlisted value is at the inclusive cap and must ship (exit 0), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/ok256.rep")"
if [ -f "$OUT256" ]; then
  grep -v '^//' "$OUT256" \
    | jq -e --arg v "$V256" 'any(.[]; .data.baseData.properties["harness.warning"] == $v)' >/dev/null 2>&1 \
    || fail "F: the 256-char value must survive UNCHANGED (never truncated) in the envelopes"
else
  fail "F: the 256-char trace did not write the dry-run file (${OUT256})"
fi

# ==============================================================================
# G. CLEAN input passes both gates on both seams — exit 0, file written, the
#    allowlisted values survive, and the output is a trace_redact fixed point.
# ==============================================================================
for seam in otlp appinsights; do
  if [ "$seam" = "otlp" ]; then flag="--dry-run-otlp-logs-to-file"; else flag="--dry-run-logs-to-file"; fi
  OUTG="${TMP_DIR}/g.${seam}.out.json"
  rc=0
  run_export "$FIX" "${TMP_DIR}/g.${seam}.rep" -- "$CLEAN" "$flag" "$OUTG" || rc=$?
  [ "$rc" = "0" ] \
    || fail "G [${seam}]: a clean log must pass the gate and exit 0, got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/g.${seam}.rep")"
  if [ -f "$OUTG" ]; then
    stripped="${TMP_DIR}/g.${seam}.stripped"
    redacted="${TMP_DIR}/g.${seam}.redacted"
    grep -v '^//' "$OUTG" > "$stripped"
    (
      cd "$FIX"
      # shellcheck source=/dev/null
      source "./scripts/trace-lib.sh"
      trace_redact < "$stripped" > "$redacted"
    ) || fail "G [${seam}]: running trace_redact over the clean output failed"
    if [ -f "$redacted" ] && ! cmp -s "$stripped" "$redacted"; then
      fail "G [${seam}]: the clean dry-run output is not a trace_redact fixed point"
    fi
  else
    fail "G [${seam}]: clean-log dry-run did not write the output file (${OUTG})"
  fi
done
# The clean MessageData output must carry the allowlisted values intact.
CLEAN_AI="${TMP_DIR}/g.appinsights.out.json"
if [ -f "$CLEAN_AI" ]; then
  grep -v '^//' "$CLEAN_AI" \
    | jq -e 'any(.[]; .data.baseData.properties["gen_ai.tool.name"] == "git")' >/dev/null 2>&1 \
    || fail "G: a plain allowlisted gen_ai.tool.name (git) must survive unchanged in the clean envelopes"
fi

# ==============================================================================
# H. Zero-network pin: no run in this sensor may ever invoke curl.
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "H: the exporter invoked curl during a gated run — the gate must stop everything before transport: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d log-export redaction-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'log-export redaction-gate contract honored\n'
