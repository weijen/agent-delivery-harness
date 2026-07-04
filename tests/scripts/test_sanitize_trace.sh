#!/usr/bin/env bash
# test_sanitize_trace.sh — regression + e2e sensor for scripts/sanitize-trace.sh
# and the committed replay fixture (issue #99, feature trace-sanitize-fixture,
# plan Phase 3).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   scripts/sanitize-trace.sh [--head N] <in.jsonl> <out.jsonl>
#
#   Turns a real (local-only) trace into a commit-safe replay fixture:
#
#   - Redaction reuse (plan D4 doctrine): every line passes through
#     trace_redact from scripts/trace-lib.sh, sourced from the sanitizer's
#     own script directory — one redaction policy, never a forked pattern
#     list. Secret shapes (e.g. ghp_…) become [REDACTED] in the output.
#   - Path scrub (fixture-specific, beyond the runtime redactor): absolute
#     home-rooted paths (/Users/<name>/..., /home/<name>/...) anywhere in a
#     span — harness.worktree, harness.summary, args — are rewritten to the
#     PINNED placeholder <SCRUBBED_PATH>; no '/Users/' or '/home/' substring
#     may survive in the output.
#   - Span-window trim (PINNED option shape): --head N keeps only the first
#     N spans of the input, sanitized; without --head all spans are kept.
#     Output line order mirrors input line order.
#   - Fail-closed leak audit: after sanitizing, the sanitizer audits its OWN
#     OUTPUT independently (secret shapes AND home-rooted absolute paths).
#     If a leak survives — e.g. the sourced redactor is broken/no-op — the
#     sanitizer exits NON-ZERO and does not leave a leaking file at
#     <out.jsonl>. Exit 0 with a leak on disk is the one forbidden outcome.
#   - Output stays valid JSONL and passes the EXISTING validator in path
#     mode: ./scripts/validate-trace.sh <out.jsonl> exits 0 with zero
#     VIOLATION findings (the 'unexpected trace location' WARNING is
#     expected for a fixture path and tolerated).
#   - Human gate (governance): the sanitizer prints a footer stating that
#     human review is required before commit (committing a fixture is a
#     human act; AGENTS.md sensitivity rules apply).
#
#   Committed-fixture leg (AC: at least one real failed run converted into a
#   sanitized replay fixture consumed by an existing sensor):
#     tests/evals/fixtures/traces/issue-97-deviation.trace.jsonl
#   must exist, pass ./scripts/validate-trace.sh path mode with zero
#   violations, contain at least one deviation span
#   (harness.lifecycle_step == "deviation" on any span type), contain NO
#   home-rooted absolute path, and be a fixed point of trace_redact (the
#   audit oracle would not alter it — no secret shape on disk).
#
# Exit codes: 0 sanitize/fixture contract honored · 1 a contract obligation
# regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANITIZER="${ROOT}/scripts/sanitize-trace.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
FIXTURE="${ROOT}/tests/evals/fixtures/traces/issue-97-deviation.trace.jsonl"
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

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required to validate sanitized trace output"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found (${CONTRACT})"
[ -f "$TRACE_LIB" ] \
  || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB}) — trace_redact is the sanitizer's redaction oracle"
[ -f "$ISSUE_LIB" ] \
  || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB}) — validate-trace.sh depends on it"
[ -f "$VALIDATOR" ] \
  || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR}) — the existing consumer of the fixture is missing"

# Pinned PATH: real tools only, isolated from the developer's ambient shell.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cksum; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done

# Planted leak shapes (synthetic; never real credentials).
GHP="ghp_FAKE0FIXTURE0SECRET0TOKEN0ABCDEFGH"
ABS_WT="/Users/testuser/code/agent-delivery-harness-worktrees/issue-97"
ABS_HOME="/home/testuser/code/agent-delivery-harness"

# ==============================================================================
# A. Committed replay fixture leg (runs first so a RED report shows BOTH the
#    missing fixture and the missing sanitizer).
# ==============================================================================
if [ -f "$FIXTURE" ]; then
  # A1. Consumed by the EXISTING sensor: validator path mode, zero violations.
  frc=0
  (cd "$ROOT" && PATH="$BIN" "./scripts/validate-trace.sh" "$FIXTURE") \
    > "${TMP_DIR}/fx.out" 2> "${TMP_DIR}/fx.err" || frc=$?
  [ "$frc" = "0" ] \
    || fail "committed fixture must pass validate-trace.sh path mode (exit 0), got ${frc}: $(tr '\n' '|' < "${TMP_DIR}/fx.out")"
  grep -q 'VIOLATION' "${TMP_DIR}/fx.out" \
    && fail "committed fixture must produce zero VIOLATION findings: $(tr '\n' '|' < "${TMP_DIR}/fx.out")"

  # A2. Carries the failure signal: at least one deviation span (any type).
  jq -es 'any(.[]; .["harness.lifecycle_step"] == "deviation")' "$FIXTURE" >/dev/null 2>&1 \
    || fail "committed fixture must contain at least one deviation span (harness.lifecycle_step == \"deviation\")"

  # A3. Commit-safe: no home-rooted absolute path survived sanitization.
  grep -qE '/(Users|home)/' "$FIXTURE" \
    && fail "committed fixture still carries a home-rooted absolute path (/Users/... or /home/...) — path scrub failed or was bypassed"

  # A4. Commit-safe: the fixture is a fixed point of trace_redact (the one
  #     redaction oracle) — no secret shape survives on disk.
  redacted_fx="${TMP_DIR}/fixture.redacted"
  (
    cd "$ROOT"
    # shellcheck source=/dev/null
    source "./scripts/trace-lib.sh"
    trace_redact < "$FIXTURE" > "$redacted_fx"
  ) || fail "running trace_redact over the committed fixture failed"
  if [ -f "$redacted_fx" ] && ! cmp -s "$FIXTURE" "$redacted_fx"; then
    fail "trace_redact would alter the committed fixture — a secret-shaped token is on disk"
  fi
else
  fail "committed replay fixture not found at tests/evals/fixtures/traces/issue-97-deviation.trace.jsonl (AC: one real failed run converted into a sanitized fixture)"
fi

# ==============================================================================
# RED gate: the sanitizer under test must exist before behavior can run.
# ==============================================================================
[ -f "$SANITIZER" ] \
  || { fail "scripts/sanitize-trace.sh not found (${SANITIZER}) — the sanitizer for feature trace-sanitize-fixture (issue #99 Phase 3) is not implemented yet"; \
       printf '\n%d sanitize-trace contract violation(s).\n' "$fails" >&2; exit 1; }
[ -x "$SANITIZER" ] \
  || hard_fail "scripts/sanitize-trace.sh exists but is not executable (${SANITIZER})"

# --- Fixture repo mirroring the harness layout (sanitizer resolves its libs
#     and the validator resolves the contract relative to their own dirs) -----
FIX="${TMP_DIR}/fixture-repo"
mkdir -p "${FIX}/scripts" "${FIX}/docs/evaluation"
cp "$SANITIZER" "${FIX}/scripts/sanitize-trace.sh"
cp "$TRACE_LIB" "${FIX}/scripts/trace-lib.sh"
cp "$ISSUE_LIB" "${FIX}/scripts/issue-lib.sh"
cp "$VALIDATOR" "${FIX}/scripts/validate-trace.sh"
cp "$CONTRACT" "${FIX}/docs/evaluation/trace-schema.v1.json"
chmod +x "${FIX}/scripts/sanitize-trace.sh" "${FIX}/scripts/validate-trace.sh"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.name "Harness Test"
git -C "$FIX" config user.email "harness-test@example.invalid"

# Synthetic 5-span input: schema-valid, unfinished (no finish step, so the
# validator's completeness pass is skipped), carrying a planted ghp_ secret
# and home-rooted absolute paths in harness.worktree and harness.summary.
IN="${TMP_DIR}/in.trace.jsonl"
cat > "$IN" <<JSONL
{"schema_version":1,"timestamp":"2026-07-04T10:00:00Z","span":"lifecycle","harness.issue":97,"harness.version":"abc1234","harness.lifecycle_step":"preflight","harness.worktree":"${ABS_WT}"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:01Z","span":"tool","harness.issue":97,"harness.version":"abc1234","gen_ai.tool.name":"git","harness.summary":"checkout under ${ABS_HOME} completed"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:02Z","span":"agent","harness.issue":97,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"deviation","harness.outcome":"blocked","harness.summary":"detached HEAD left in ${ABS_WT}; rotated ${GHP} afterwards"}
{"schema_version":1,"timestamp":"2026-07-04T10:00:03Z","span":"model","harness.issue":97,"harness.version":"abc1234","gen_ai.request.model":"example-model","gen_ai.usage.input_tokens":18000,"gen_ai.usage.output_tokens":4000}
{"schema_version":1,"timestamp":"2026-07-04T10:00:04Z","span":"tool","harness.issue":97,"harness.version":"abc1234","gen_ai.tool.name":"gh"}
JSONL

run_sanitize() { # run_sanitize <scripts-dir> <out-report> <args...>
  local sdir="$1" rep="$2"; shift 2
  (cd "$FIX" && PATH="$BIN" "${sdir}/sanitize-trace.sh" "$@") > "$rep" 2>&1
}

# ==============================================================================
# B. Happy path: redact + path scrub, all spans kept, validator-clean output.
# ==============================================================================
OUT1="${TMP_DIR}/out1.trace.jsonl"
run_sanitize "${FIX}/scripts" "${TMP_DIR}/s1.out" "$IN" "$OUT1" \
  || { cat "${TMP_DIR}/s1.out"; fail "sanitize-trace.sh on a leaky-but-valid trace must exit 0"; }
[ -f "$OUT1" ] || fail "sanitizer must write the output file (${OUT1})"
if [ -f "$OUT1" ]; then
  [ "$(wc -l < "$OUT1" | tr -d '[:space:]')" = "5" ] \
    || fail "without --head all 5 spans must be kept (got $(wc -l < "$OUT1" | tr -d '[:space:]'))"

  grep -qF -- "$GHP" "$OUT1" \
    && fail "planted ghp_ secret survived sanitization (trace_redact reuse bypassed)"
  grep -qF '[REDACTED]' "$OUT1" \
    || fail "sanitized output must mask the planted secret as [REDACTED] (trace_redact's mask)"

  grep -qE '/(Users|home)/' "$OUT1" \
    && fail "home-rooted absolute path survived the path scrub in the output"
  grep -qF '<SCRUBBED_PATH>' "$OUT1" \
    || fail "scrubbed paths must be rewritten to the pinned placeholder <SCRUBBED_PATH>"

  jq -es 'any(.[]; .["harness.lifecycle_step"] == "deviation")' "$OUT1" >/dev/null 2>&1 \
    || fail "sanitization must preserve the deviation span (the diagnostic payload)"

  # Consumed by the existing validator, path mode: exit 0, zero VIOLATIONs
  # (the unexpected-location WARNING is expected and tolerated).
  vrc=0
  (cd "$FIX" && PATH="$BIN" "./scripts/validate-trace.sh" "$OUT1") \
    > "${TMP_DIR}/v1.out" 2> "${TMP_DIR}/v1.err" || vrc=$?
  [ "$vrc" = "0" ] \
    || fail "sanitized output must pass validate-trace.sh path mode (exit 0), got ${vrc}: $(tr '\n' '|' < "${TMP_DIR}/v1.out")"
  grep -q 'VIOLATION' "${TMP_DIR}/v1.out" \
    && fail "sanitized output must produce zero VIOLATION findings: $(tr '\n' '|' < "${TMP_DIR}/v1.out")"
fi
grep -qi 'human review' "${TMP_DIR}/s1.out" \
  || fail "sanitizer must print the human-review-before-commit footer (governance: committing is a human act)"

# ==============================================================================
# C. Span-window trim: --head N keeps the first N sanitized spans, in order.
# ==============================================================================
OUT2="${TMP_DIR}/out2.trace.jsonl"
run_sanitize "${FIX}/scripts" "${TMP_DIR}/s2.out" --head 3 "$IN" "$OUT2" \
  || { cat "${TMP_DIR}/s2.out"; fail "sanitize-trace.sh --head 3 must exit 0"; }
if [ -f "$OUT2" ]; then
  [ "$(wc -l < "$OUT2" | tr -d '[:space:]')" = "3" ] \
    || fail "--head 3 must keep exactly the first 3 spans (got $(wc -l < "$OUT2" | tr -d '[:space:]'))"
  jq -es '.[0].timestamp == "2026-07-04T10:00:00Z"' "$OUT2" >/dev/null 2>&1 \
    || fail "--head must keep the FIRST spans in input order (line 1 timestamp drifted)"
  jq -es '.[2]["harness.lifecycle_step"] == "deviation"' "$OUT2" >/dev/null 2>&1 \
    || fail "--head 3 must include input line 3 (the deviation span) as output line 3"
  grep -qE '/(Users|home)/' "$OUT2" \
    && fail "--head output must still be path-scrubbed"
  grep -qF -- "$GHP" "$OUT2" \
    && fail "--head output must still be redacted"
else
  fail "--head 3 run did not write the output file (${OUT2})"
fi

# ==============================================================================
# D. Fail-closed leak audit: with a MUTANT no-op trace_redact sourced from the
#    sanitizer's script dir, the secret survives the redaction pass — the
#    independent output audit must catch it: NON-ZERO exit and no leaking
#    file left at <out>. (Exit 0 + leak on disk is the forbidden outcome.)
# ==============================================================================
MUT="${TMP_DIR}/mutant-repo"
mkdir -p "${MUT}/scripts" "${MUT}/docs/evaluation"
cp "$SANITIZER" "${MUT}/scripts/sanitize-trace.sh"
cp "$ISSUE_LIB" "${MUT}/scripts/issue-lib.sh"
cp "$CONTRACT" "${MUT}/docs/evaluation/trace-schema.v1.json"
chmod +x "${MUT}/scripts/sanitize-trace.sh"
cat > "${MUT}/scripts/trace-lib.sh" <<'SH'
#!/usr/bin/env bash
# MUTANT trace-lib for the fail-closed audit test: redaction is a no-op.
trace_redact() { cat; }
trace_warn() { printf 'warning: %s\n' "$*" >&2; }
SH

OUT3="${TMP_DIR}/out3.trace.jsonl"
mrc=0
run_sanitize "${MUT}/scripts" "${TMP_DIR}/s3.out" "$IN" "$OUT3" || mrc=$?
[ "$mrc" != "0" ] \
  || fail "fail-closed audit: with a no-op redactor the sanitizer must exit NON-ZERO (a leak survived), got exit 0"
if [ -f "$OUT3" ] && grep -qF -- "$GHP" "$OUT3"; then
  fail "fail-closed audit: the sanitizer left a leaking output file at <out> (raw ghp_ secret on disk after non-zero exit)"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d sanitize-trace contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'sanitize-trace + committed replay fixture contract honored\n'
