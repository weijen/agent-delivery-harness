#!/usr/bin/env bash
# test_render_action_log.sh — regression sensor for scripts/render-action-log.sh
# (issue #332, feature render-action-log).
#
# Contract under test:
#   scripts/render-action-log.sh <issue-number>
#   scripts/render-action-log.sh <path/to/trace.jsonl>
#
#   Reads span=="agent" lines from trace.jsonl and atomically rewrites the
#   ## Action Log section of progress.md. Warn-never-fail: always exits 0.
#
# Legs:
#   1. Two agent spans → bullets appear verbatim under ## Action Log (path mode)
#   2. Missing ## Action Log heading → exit 0, progress.md unchanged
#   3. Empty trace.jsonl (no agent spans) → scaffold placeholder preserved
#   4. CLI edge cases: no args → exit 0; missing trace file → exit 0 + stderr
#   5. TEETH: mutant renderer (wrong jq field) no longer produces [conductor]
#   6. Malformed JSON trace → warn + leave progress.md unchanged
#   7. Unreadable trace file → warn + leave progress.md unchanged (skipped as root)
#   8. Prefix collision: ## Action Log Archive not treated as ## Action Log
#   9. H1 boundary: # heading after ## Action Log is preserved, not deleted
#  10. Permissions: original file mode preserved after atomic replacement
#  11. Printf guard: bullets write failure → warn + exit 0 + progress.md unchanged
#      (deterministic under root: uses directory target, not chmod 000)
#  12. Live layout: issue-number mode finds worktree progress.md when main-root is absent
#  13. Symlink rejection: symlinked progress.md or issue dir → warn + exit 0 + unchanged
#  14. Non-object JSON trace → warn + exit 0 + progress.md unchanged
#      (parseable arrays, null, and scalars must not silently overwrite real bullets)
#  15. Symlink ancestor: trace dir logical path traverses a symlinked ancestor (not the
#      dir itself) → warn + exit 0 + progress.md unchanged
#      (current -L "$TRACE_DIR" only checks the final component, not ancestors)
#  16. Mode fault injection: stat failure or chmod failure → warn + exit 0 + unchanged
#      (deterministic via fakebin; proves current || true swallowing causes wrong-mode publish)
#
# Exit codes: 0 all legs pass · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${ROOT}/scripts/render-action-log.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to run render-action-log tests"

# RED gate: the renderer must exist before any leg can run.
[ -f "$RENDERER" ] \
  || fail "scripts/render-action-log.sh not found (${RENDERER}) — the Action Log renderer for feature render-action-log (issue #332) is not implemented yet"

# --- Helpers ------------------------------------------------------------------

# scaffold_progress <dir>: minimal progress.md with ## Action Log + placeholder.
scaffold_progress() {
  local dir="$1"
  cat > "${dir}/progress.md" <<'MD'
# Issue fixture progress

Status: in progress.

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD
}

# make_spans <file>: two agent spans for legs that need real span content.
make_spans() {
  local file="$1"
  printf '%s\n' \
    '{"schema_version":1,"span":"agent","span_id":"abc1","timestamp":"2026-07-01T00:00:00Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"feature_start","harness.feature_id":"render-action-log","harness.outcome":"pass","harness.summary":"selected renderer feature","harness.issue":332}' \
    > "$file"
  printf '%s\n' \
    '{"schema_version":1,"span":"agent","span_id":"abc2","timestamp":"2026-07-01T00:00:01Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"render-action-log","harness.outcome":"pass","harness.summary":"RED confirmed for right reason","harness.issue":332}' \
    >> "$file"
}

# ============================================================================
# Leg 1: Two agent spans → bullets appear under ## Action Log (path mode)
# ============================================================================
LEG1="${TMP_DIR}/leg1"
mkdir -p "$LEG1"
make_spans "${LEG1}/trace.jsonl"
scaffold_progress "$LEG1"

RC1=0
bash "$RENDERER" "${LEG1}/trace.jsonl" 2>/dev/null || RC1=$?
[ "$RC1" -eq 0 ] \
  || fail "leg1: renderer must exit 0 (warn-never-fail); got exit ${RC1}"

grep -q '^## Action Log' "${LEG1}/progress.md" \
  || fail "leg1: ## Action Log heading must survive rendering"

grep -qF -- '- [conductor] feature_start render-action-log pass — selected renderer feature' \
  "${LEG1}/progress.md" \
  || fail "leg1: first span must produce bullet '- [conductor] feature_start render-action-log pass — selected renderer feature'"

grep -qF -- '- [generator-subagent] red_handback render-action-log pass — RED confirmed for right reason' \
  "${LEG1}/progress.md" \
  || fail "leg1: second span must produce bullet '- [generator-subagent] red_handback render-action-log pass — RED confirmed for right reason'"

# Bullets must appear AFTER the ## Action Log heading line.
AL_LINE="$(grep -n '^## Action Log' "${LEG1}/progress.md" | head -1 | cut -d: -f1)"
B1_LINE="$(grep -n 'feature_start render-action-log pass' "${LEG1}/progress.md" | head -1 | cut -d: -f1)"
[ "$B1_LINE" -gt "$AL_LINE" ] \
  || fail "leg1: first bullet (line ${B1_LINE}) must appear after ## Action Log heading (line ${AL_LINE})"

# Scaffold placeholder must NOT remain (it is replaced by real bullets).
if grep -qF -- '_Record conductor handbacks' "${LEG1}/progress.md"; then
  fail "leg1: scaffold placeholder must be replaced by the rendered bullets"
fi

# ============================================================================
# Leg 2: Missing ## Action Log heading → exit 0, progress.md unchanged
# ============================================================================
LEG2="${TMP_DIR}/leg2"
mkdir -p "$LEG2"
make_spans "${LEG2}/trace.jsonl"
cat > "${LEG2}/progress.md" <<'MD'
# Issue fixture progress

Status: in progress.

No action log section here.
MD
BEFORE2="$(cat "${LEG2}/progress.md")"

RC2=0
STDERR2="$(bash "$RENDERER" "${LEG2}/trace.jsonl" 2>&1)" || RC2=$?
[ "$RC2" -eq 0 ] \
  || fail "leg2: renderer must exit 0 when ## Action Log heading is missing; got exit ${RC2}"

AFTER2="$(cat "${LEG2}/progress.md")"
[ "$BEFORE2" = "$AFTER2" ] \
  || fail "leg2: progress.md must be unchanged when ## Action Log heading is missing"

printf '%s\n' "$STDERR2" | grep -qi 'action.log\|warn\|no.*action\|missing\|heading\|section' \
  || fail "leg2: renderer must warn to stderr when ## Action Log heading is missing"

# ============================================================================
# Leg 3: Empty trace.jsonl (no agent spans) → scaffold placeholder preserved
# ============================================================================
LEG3="${TMP_DIR}/leg3"
mkdir -p "$LEG3"
printf '' > "${LEG3}/trace.jsonl"
scaffold_progress "$LEG3"

RC3=0
bash "$RENDERER" "${LEG3}/trace.jsonl" 2>/dev/null || RC3=$?
[ "$RC3" -eq 0 ] \
  || fail "leg3: renderer must exit 0 for empty trace; got exit ${RC3}"

grep -qF -- '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._' \
  "${LEG3}/progress.md" \
  || fail "leg3: scaffold placeholder must appear in Action Log when trace has no agent spans"

# Also test with non-agent spans (lifecycle spans should not produce bullets).
LEG3B="${TMP_DIR}/leg3b"
mkdir -p "$LEG3B"
printf '%s\n' \
  '{"schema_version":1,"span":"lifecycle","span_id":"xyz1","timestamp":"2026-07-01T00:00:00Z","harness.lifecycle_step":"worktree_create","harness.issue":332}' \
  > "${LEG3B}/trace.jsonl"
scaffold_progress "$LEG3B"

RC3B=0
bash "$RENDERER" "${LEG3B}/trace.jsonl" 2>/dev/null || RC3B=$?
[ "$RC3B" -eq 0 ] \
  || fail "leg3b: renderer must exit 0 for trace with only non-agent spans; got exit ${RC3B}"

grep -qF -- '- _Record conductor handbacks' "${LEG3B}/progress.md" \
  || fail "leg3b: scaffold placeholder must appear when trace has no agent spans"

# ============================================================================
# Leg 4: CLI edge cases
# ============================================================================

# 4a: no arguments → exit 0 (warn-never-fail)
RC4A=0
bash "$RENDERER" 2>/dev/null || RC4A=$?
[ "$RC4A" -eq 0 ] \
  || fail "leg4a: renderer with no args must exit 0; got exit ${RC4A}"

# 4b: missing trace file → exit 0 + stderr warning
RC4B=0
STDERR4B="$(bash "$RENDERER" "${TMP_DIR}/nonexistent-trace.jsonl" 2>&1)" || RC4B=$?
[ "$RC4B" -eq 0 ] \
  || fail "leg4b: renderer must exit 0 for missing trace file; got exit ${RC4B}"
printf '%s\n' "$STDERR4B" | grep -qi 'not found\|missing\|warn\|cannot\|no such' \
  || fail "leg4b: renderer must warn to stderr for a missing trace file"

# 4c: issue-number mode with a real git repo
NUM_REPO="${TMP_DIR}/num-repo"
mkdir -p "$NUM_REPO"
git -C "$NUM_REPO" init -q -b main
git -C "$NUM_REPO" config user.name "Harness Test"
git -C "$NUM_REPO" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${NUM_REPO}/README.md"
git -C "$NUM_REPO" add README.md
git -C "$NUM_REPO" commit -q -m "init"
mkdir -p "${NUM_REPO}/.copilot-tracking/issues/issue-07"
make_spans "${NUM_REPO}/.copilot-tracking/issues/issue-07/trace.jsonl"
cat > "${NUM_REPO}/.copilot-tracking/issues/issue-07/progress.md" <<'MD'
# Issue 7 fixture

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD

RC4C=0
(cd "$NUM_REPO" && bash "$RENDERER" 7 2>/dev/null) || RC4C=$?
[ "$RC4C" -eq 0 ] \
  || fail "leg4c: issue-number mode must exit 0; got exit ${RC4C}"
grep -qF -- '- [conductor] feature_start render-action-log pass' \
  "${NUM_REPO}/.copilot-tracking/issues/issue-07/progress.md" \
  || fail "leg4c: issue-number mode must render bullets into the correct progress.md"

# ============================================================================
# Leg 5 (TEETH): Mutated renderer extracts wrong jq field → [conductor] absent
# Proves that leg1's assertions would catch a wrong-field extraction.
# ============================================================================
MUTANT_DIR="${TMP_DIR}/mutant"
mkdir -p "$MUTANT_DIR"
# Replace gen_ai.agent.name with harness.lifecycle_step in the jq filter;
# for the first span (conductor/feature_start) this produces [feature_start]
# instead of [conductor], proving leg1's grep -qF '- [conductor]' would fail.
sed 's/gen_ai\.agent\.name/harness.lifecycle_step/g' "$RENDERER" \
  > "${MUTANT_DIR}/render-action-log.sh"
chmod +x "${MUTANT_DIR}/render-action-log.sh"

LEG5="${TMP_DIR}/leg5"
mkdir -p "$LEG5"
make_spans "${LEG5}/trace.jsonl"
scaffold_progress "$LEG5"

RC5=0
bash "${MUTANT_DIR}/render-action-log.sh" "${LEG5}/trace.jsonl" 2>/dev/null || RC5=$?
[ "$RC5" -eq 0 ] \
  || fail "leg5: mutant renderer must still exit 0; got exit ${RC5}"

if grep -qF -- '- [conductor]' "${LEG5}/progress.md"; then
  fail "leg5 (TEETH): mutant renderer still produces [conductor] prefix — leg1 assertion would NOT catch a wrong-field extraction"
fi
if ! grep -qF -- '- [feature_start]' "${LEG5}/progress.md"; then
  fail "leg5 (TEETH): mutant renderer did not produce [feature_start] prefix; mutation may not have applied to the jq filter"
fi

# ============================================================================
# Leg 6: Malformed JSON trace → warn + leave progress.md unchanged
# The renderer must NOT silently overwrite the Action Log with the placeholder
# when jq cannot parse the trace content.
# Uses a progress.md that has real bullets so any overwrite is detectable.
# ============================================================================
LEG6="${TMP_DIR}/leg6"
mkdir -p "$LEG6"
printf '{invalid json\n{also broken\n' > "${LEG6}/trace.jsonl"
cat > "${LEG6}/progress.md" <<'MD'
# Issue fixture progress

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
BEFORE6="$(cat "${LEG6}/progress.md")"

RC6=0
STDERR6="$(bash "$RENDERER" "${LEG6}/trace.jsonl" 2>&1)" || RC6=$?
[ "$RC6" -eq 0 ] \
  || fail "leg6: renderer must exit 0 for malformed trace; got exit ${RC6}"

AFTER6="$(cat "${LEG6}/progress.md")"
[ "$BEFORE6" = "$AFTER6" ] \
  || fail "leg6: progress.md must be unchanged for malformed trace (real bullet was overwritten)"

printf '%s\n' "$STDERR6" | grep -qi 'warn\|parse\|fail\|error\|malform' \
  || fail "leg6: renderer must emit a warning to stderr for a malformed trace"

# ============================================================================
# Leg 7: Unreadable trace file → warn + leave progress.md unchanged
# Skipped when running as root because chmod 000 does not restrict root.
# Uses a progress.md that has real bullets so any overwrite is detectable.
# ============================================================================
if [ "$(id -u)" -eq 0 ]; then
  printf 'note: skipping leg7 (unreadable file) — running as root\n'
else
  LEG7="${TMP_DIR}/leg7"
  mkdir -p "$LEG7"
  printf '{"schema_version":1,"span":"agent","gen_ai.agent.name":"conductor"}\n' \
    > "${LEG7}/trace.jsonl"
  chmod 000 "${LEG7}/trace.jsonl"
  cat > "${LEG7}/progress.md" <<'MD'
# Issue fixture progress

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
  BEFORE7="$(cat "${LEG7}/progress.md")"

  RC7=0
  STDERR7="$(bash "$RENDERER" "${LEG7}/trace.jsonl" 2>&1)" || RC7=$?
  [ "$RC7" -eq 0 ] \
    || fail "leg7: renderer must exit 0 for unreadable trace; got exit ${RC7}"

  AFTER7="$(cat "${LEG7}/progress.md")"
  [ "$BEFORE7" = "$AFTER7" ] \
    || fail "leg7: progress.md must be unchanged for unreadable trace (real bullet was overwritten)"

  printf '%s\n' "$STDERR7" | grep -qi 'warn\|fail\|error\|cannot\|permission\|read\|parse' \
    || fail "leg7: renderer must emit a warning to stderr for an unreadable trace"
fi

# ============================================================================
# Leg 8: Prefix collision — ## Action Log Archive must not be touched
# The heading pattern must match ## Action Log exactly, not as a prefix.
# ============================================================================
LEG8="${TMP_DIR}/leg8"
mkdir -p "$LEG8"
make_spans "${LEG8}/trace.jsonl"
cat > "${LEG8}/progress.md" <<'MD'
# Issue fixture

## Action Log

- old entry

## Action Log Archive

- archived thing

## Other Section

something else
MD

RC8=0
bash "$RENDERER" "${LEG8}/trace.jsonl" 2>/dev/null || RC8=$?
[ "$RC8" -eq 0 ] \
  || fail "leg8: renderer must exit 0; got exit ${RC8}"

grep -qF '## Action Log Archive' "${LEG8}/progress.md" \
  || fail "leg8: ## Action Log Archive heading must survive rendering"

grep -qF -- '- archived thing' "${LEG8}/progress.md" \
  || fail "leg8: content under ## Action Log Archive must not be deleted by the renderer"

# ============================================================================
# Leg 9: H1 boundary — a # heading following ## Action Log must be preserved
# The section-end condition must recognise H1 (# ) not only H2 (## ).
# ============================================================================
LEG9="${TMP_DIR}/leg9"
mkdir -p "$LEG9"
make_spans "${LEG9}/trace.jsonl"
cat > "${LEG9}/progress.md" <<'MD'
# Issue fixture

## Action Log

- old entry

# Final Notes

Important final content.
MD

RC9=0
bash "$RENDERER" "${LEG9}/trace.jsonl" 2>/dev/null || RC9=$?
[ "$RC9" -eq 0 ] \
  || fail "leg9: renderer must exit 0; got exit ${RC9}"

grep -qF '# Final Notes' "${LEG9}/progress.md" \
  || fail "leg9: # Final Notes heading must survive rendering (was deleted)"

grep -qF 'Important final content.' "${LEG9}/progress.md" \
  || fail "leg9: content under # Final Notes must not be deleted by the renderer"

# ============================================================================
# Leg 10: Permissions — original file mode preserved after atomic replacement
# mktemp creates 0600 files; mv without chmod would silently change progress.md
# mode from 644 to 600. The renderer must preserve the original mode before mv.
# ============================================================================
LEG10="${TMP_DIR}/leg10"
mkdir -p "$LEG10"
make_spans "${LEG10}/trace.jsonl"
scaffold_progress "$LEG10"
chmod 644 "${LEG10}/progress.md"

RC10=0
bash "$RENDERER" "${LEG10}/trace.jsonl" 2>/dev/null || RC10=$?
[ "$RC10" -eq 0 ] \
  || fail "leg10: renderer must exit 0; got exit ${RC10}"

PERMS10=""
PERMS10="$(stat -c '%a' "${LEG10}/progress.md" 2>/dev/null)" \
  || PERMS10="$(stat -f '%OLp' "${LEG10}/progress.md" 2>/dev/null)" \
  || true
[ "$PERMS10" = "644" ] \
  || fail "leg10: progress.md permissions must be preserved after rendering; expected 644, got '${PERMS10}'"

# ============================================================================
# Leg 11: Printf guard — bullets write failure → warn + exit 0 + unchanged
# A fake mktemp makes the bullets temp file a directory (simulating ENOSPC /
# quota or any IO error that prevents writing).  Redirecting printf output to
# a directory always fails — even as root — because the kernel rejects O_WRONLY
# on a directory regardless of DAC mode bits.  This makes the sensor
# deterministic under root, unlike the former chmod 000 approach which root
# ignores.
#
# Root-safety proof (RED against chmod 000, GREEN after directory approach):
# A companion no-op chmod (simulating root's DAC bypass) is put on PATH first.
# With chmod 000 the bullets file stays writable; printf succeeds; progress.md
# is changed; the assertion below would FAIL — confirming root fragility of the
# old approach.  With the directory approach chmod is irrelevant; the printf
# write fails regardless; progress.md remains unchanged; assertion PASSES.
# ============================================================================
REAL_MKTEMP_PATH="$(command -v mktemp)"
LEG11="${TMP_DIR}/leg11"
mkdir -p "${LEG11}/fakebin"

# no-op chmod for the root-safety proof (simulates root ignoring DAC mode bits)
cat > "${LEG11}/fakebin/chmod" <<'CHEOF'
#!/usr/bin/env bash
exit 0
CHEOF
chmod +x "${LEG11}/fakebin/chmod"

# Root-safety RED probe: with chmod as a no-op, the old chmod 000 approach
# leaves the bullets file writable → printf succeeds → progress.md is changed.
# This confirms the old mechanism is not root-safe.
LEG11_ROOT_SIM="${TMP_DIR}/leg11-root-sim"
mkdir -p "${LEG11_ROOT_SIM}/fakebin"
# same no-op chmod
cp "${LEG11}/fakebin/chmod" "${LEG11_ROOT_SIM}/fakebin/chmod"
cat > "${LEG11_ROOT_SIM}/fakebin/mktemp" <<MKEOF
#!/usr/bin/env bash
RESULT="\$("${REAL_MKTEMP_PATH}" "\$@")" || exit \$?
for _A in "\$@"; do _LAST="\$_A"; done
case "\$_LAST" in
  *render-bullets*) chmod 000 "\$RESULT" ;;
esac
printf '%s\n' "\$RESULT"
MKEOF
chmod +x "${LEG11_ROOT_SIM}/fakebin/mktemp"
make_spans "${LEG11_ROOT_SIM}/trace.jsonl"
scaffold_progress "$LEG11_ROOT_SIM"
BEFORE11_SIM="$(cat "${LEG11_ROOT_SIM}/progress.md")"

PATH="${LEG11_ROOT_SIM}/fakebin:${PATH}" \
  bash "$RENDERER" "${LEG11_ROOT_SIM}/trace.jsonl" 2>/dev/null || true
AFTER11_SIM="$(cat "${LEG11_ROOT_SIM}/progress.md")"
# Under root (no-op chmod), progress.md is changed — that is the expected failure.
# If it is NOT changed here, the root-sim fakebin is misconfigured.
[ "$BEFORE11_SIM" != "$AFTER11_SIM" ] \
  || fail "leg11-root-sim: fakebin no-op chmod did not demonstrate root fragility — chmod 000 approach must be shown insecure under root (progress.md should have been overwritten)"
printf 'note: leg11-root-sim confirmed: chmod 000 is not root-safe (progress.md overwritten with no-op chmod)\n'

# Main leg 11: directory approach — write to a directory always fails even as root.
# Fake mktemp: for the render-bullets template, swap the file for a directory
# so the renderer's guarded printf always fails.
make_spans "${LEG11}/trace.jsonl"
scaffold_progress "$LEG11"
BEFORE11="$(cat "${LEG11}/progress.md")"

cat > "${LEG11}/fakebin/mktemp" <<MKEOF
#!/usr/bin/env bash
RESULT="\$("${REAL_MKTEMP_PATH}" "\$@")" || exit \$?
for _A in "\$@"; do _LAST="\$_A"; done
case "\$_LAST" in
  *render-bullets*) rm -f "\$RESULT"; mkdir "\$RESULT" ;;
esac
printf '%s\n' "\$RESULT"
MKEOF
chmod +x "${LEG11}/fakebin/mktemp"

RC11=0
STDERR11="$(PATH="${LEG11}/fakebin:${PATH}" bash "$RENDERER" "${LEG11}/trace.jsonl" 2>&1)" \
  || RC11=$?
[ "$RC11" -eq 0 ] \
  || fail "leg11: renderer must exit 0 when bullets write fails (warn-never-fail); got exit ${RC11}"

AFTER11="$(cat "${LEG11}/progress.md")"
[ "$BEFORE11" = "$AFTER11" ] \
  || fail "leg11: progress.md must be unchanged when bullets write fails"

printf '%s\n' "$STDERR11" | grep -qi 'warn\|fail\|write\|bullet\|temp' \
  || fail "leg11: renderer must warn to stderr when bullets write fails"

# ============================================================================
# Leg 12: Live layout — issue-number mode finds worktree progress.md when
# main-root progress.md is absent.
# On live runs the invoking worktree holds progress.md while trace.jsonl lives
# in the main checkout's tracking directory.  The renderer must fall back to
# git rev-parse --show-toplevel when the main-root progress.md is absent.
# This leg is RED against the pre-fix renderer (it will warn and exit 0 without
# rendering because it only looks in the main root) and GREEN after the fix.
# ============================================================================
MAIN_REPO12="${TMP_DIR}/main-repo-12"
WT12="${TMP_DIR}/wt-12"
mkdir -p "$MAIN_REPO12"
git -C "$MAIN_REPO12" init -q -b main
git -C "$MAIN_REPO12" config user.name "Harness Test"
git -C "$MAIN_REPO12" config user.email "harness-test@example.invalid"
printf 'fixture\n' > "${MAIN_REPO12}/README.md"
git -C "$MAIN_REPO12" add README.md
git -C "$MAIN_REPO12" commit -q -m "init"

# trace.jsonl in the main root's tracking dir; NO progress.md there
mkdir -p "${MAIN_REPO12}/.copilot-tracking/issues/issue-12"
make_spans "${MAIN_REPO12}/.copilot-tracking/issues/issue-12/trace.jsonl"

# progress.md lives in the linked worktree's tracking dir
git -C "$MAIN_REPO12" worktree add -q "$WT12" -b leg12-branch
mkdir -p "${WT12}/.copilot-tracking/issues/issue-12"
cat > "${WT12}/.copilot-tracking/issues/issue-12/progress.md" <<'MD'
# Issue 12 fixture

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD

RC12=0
(cd "$WT12" && bash "$RENDERER" 12 2>/dev/null) || RC12=$?
[ "$RC12" -eq 0 ] \
  || fail "leg12: live-layout issue-number mode must exit 0; got exit ${RC12}"

grep -qF -- '- [conductor] feature_start render-action-log pass' \
  "${WT12}/.copilot-tracking/issues/issue-12/progress.md" \
  || fail "leg12: issue-number mode must render bullets into worktree's progress.md when main-root progress.md is absent"

# ============================================================================
# Leg 13: Symlink rejection — symlinked progress.md or issue dir → warn + exit 0
# A symlinked progress.md or issue artifact directory can silently redirect
# writes to an unexpected target.  The renderer must detect -L and exit 0 with
# a warning, leaving both the symlink and the target unchanged.
# 13a: progress.md is a symlink
# 13b: the issue artifact directory itself is a symlink
# ============================================================================

# 13a: progress.md is a symlink
LEG13A="${TMP_DIR}/leg13a"
LEG13A_TARGET="${TMP_DIR}/leg13a-target"
mkdir -p "$LEG13A" "$LEG13A_TARGET"
make_spans "${LEG13A}/trace.jsonl"
cat > "${LEG13A_TARGET}/real-progress.md" <<'MD'
# Issue fixture

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD
ln -s "${LEG13A_TARGET}/real-progress.md" "${LEG13A}/progress.md"
BEFORE13A="$(cat "${LEG13A_TARGET}/real-progress.md")"

RC13A=0
STDERR13A="$(bash "$RENDERER" "${LEG13A}/trace.jsonl" 2>&1)" || RC13A=$?
[ "$RC13A" -eq 0 ] \
  || fail "leg13a: renderer must exit 0 when progress.md is a symlink (warn-never-fail); got exit ${RC13A}"

AFTER13A="$(cat "${LEG13A_TARGET}/real-progress.md")"
[ "$BEFORE13A" = "$AFTER13A" ] \
  || fail "leg13a: symlink target must be unchanged when progress.md is a symlink"

printf '%s\n' "$STDERR13A" | grep -qi 'symlink\|warn\|redirect\|link' \
  || fail "leg13a: renderer must warn to stderr when progress.md is a symlink"

# 13b: issue artifact directory is a symlink
LEG13B_REAL="${TMP_DIR}/leg13b-real"
LEG13B_LINK="${TMP_DIR}/leg13b-link"
mkdir -p "$LEG13B_REAL"
make_spans "${LEG13B_REAL}/trace.jsonl"
cat > "${LEG13B_REAL}/progress.md" <<'MD'
# Issue fixture

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._
MD
ln -s "$LEG13B_REAL" "$LEG13B_LINK"
BEFORE13B="$(cat "${LEG13B_REAL}/progress.md")"

RC13B=0
STDERR13B="$(bash "$RENDERER" "${LEG13B_LINK}/trace.jsonl" 2>&1)" || RC13B=$?
[ "$RC13B" -eq 0 ] \
  || fail "leg13b: renderer must exit 0 when trace directory is a symlink (warn-never-fail); got exit ${RC13B}"

AFTER13B="$(cat "${LEG13B_REAL}/progress.md")"
[ "$BEFORE13B" = "$AFTER13B" ] \
  || fail "leg13b: real progress.md must be unchanged when trace directory is a symlink"

printf '%s\n' "$STDERR13B" | grep -qi 'symlink\|warn\|redirect\|link' \
  || fail "leg13b: renderer must warn to stderr when trace directory is a symlink"

# ============================================================================
# Leg 14: Non-object JSON trace → warn + exit 0 + progress.md unchanged
# The renderer must reject any nonblank parseable line that is not a JSON
# object.  The former `objects` filter silently discarded arrays/null/scalars,
# treating a trace containing only `[]` as having no agent spans and
# overwriting the Action Log with the scaffold placeholder even when real
# bullets were present.  All three sub-cases are RED against the pre-repair
# renderer and GREEN after the fix.
# 14a: trace = JSON array  (`[]`)
# 14b: trace = JSON null   (`null`)
# 14c: trace = JSON number (`42`)
# ============================================================================

# 14a: JSON array trace
LEG14A="${TMP_DIR}/leg14a"
mkdir -p "$LEG14A"
printf '[]\n' > "${LEG14A}/trace.jsonl"
cat > "${LEG14A}/progress.md" <<'MD'
# Issue fixture

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
BEFORE14A="$(cat "${LEG14A}/progress.md")"

RC14A=0
STDERR14A="$(bash "$RENDERER" "${LEG14A}/trace.jsonl" 2>&1)" || RC14A=$?
[ "$RC14A" -eq 0 ] \
  || fail "leg14a: renderer must exit 0 for array-valued trace (warn-never-fail); got exit ${RC14A}"

AFTER14A="$(cat "${LEG14A}/progress.md")"
[ "$BEFORE14A" = "$AFTER14A" ] \
  || fail "leg14a: progress.md must be unchanged for parseable non-object trace (array); real bullet was overwritten"

printf '%s\n' "$STDERR14A" | grep -qi 'warn\|parse\|fail\|error\|object\|non-object\|json' \
  || fail "leg14a: renderer must warn to stderr for a non-object JSON trace"

# 14b: JSON null trace
LEG14B="${TMP_DIR}/leg14b"
mkdir -p "$LEG14B"
printf 'null\n' > "${LEG14B}/trace.jsonl"
cat > "${LEG14B}/progress.md" <<'MD'
# Issue fixture

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
BEFORE14B="$(cat "${LEG14B}/progress.md")"

RC14B=0
STDERR14B="$(bash "$RENDERER" "${LEG14B}/trace.jsonl" 2>&1)" || RC14B=$?
[ "$RC14B" -eq 0 ] \
  || fail "leg14b: renderer must exit 0 for null-valued trace (warn-never-fail); got exit ${RC14B}"

AFTER14B="$(cat "${LEG14B}/progress.md")"
[ "$BEFORE14B" = "$AFTER14B" ] \
  || fail "leg14b: progress.md must be unchanged for parseable non-object trace (null); real bullet was overwritten"

printf '%s\n' "$STDERR14B" | grep -qi 'warn\|parse\|fail\|error\|object\|non-object\|json' \
  || fail "leg14b: renderer must warn to stderr for a non-object JSON trace"

# 14c: JSON number trace
LEG14C="${TMP_DIR}/leg14c"
mkdir -p "$LEG14C"
printf '42\n' > "${LEG14C}/trace.jsonl"
cat > "${LEG14C}/progress.md" <<'MD'
# Issue fixture

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
BEFORE14C="$(cat "${LEG14C}/progress.md")"

RC14C=0
STDERR14C="$(bash "$RENDERER" "${LEG14C}/trace.jsonl" 2>&1)" || RC14C=$?
[ "$RC14C" -eq 0 ] \
  || fail "leg14c: renderer must exit 0 for number-valued trace (warn-never-fail); got exit ${RC14C}"

AFTER14C="$(cat "${LEG14C}/progress.md")"
[ "$BEFORE14C" = "$AFTER14C" ] \
  || fail "leg14c: progress.md must be unchanged for parseable non-object trace (number); real bullet was overwritten"

printf '%s\n' "$STDERR14C" | grep -qi 'warn\|parse\|fail\|error\|object\|non-object\|json' \
  || fail "leg14c: renderer must warn to stderr for a non-object JSON trace"

# ============================================================================
# Leg 15: Symlink ancestor — trace dir logical path traverses a symlinked
# ancestor (but the dir itself is NOT a symlink) → warn + exit 0 + unchanged
#
# The current -L "$TRACE_DIR" check only inspects the final path component.
# A path like linked-root/issue/trace.jsonl bypasses it: linked-root is the
# symlink but linked-root/issue is a real directory.  The renderer must compare
# pwd -P (physical) vs pwd -L (logical) to detect ancestor symlinks.
# macOS /var→/private/var normalisation is applied to the logical path so that
# legitimate mktemp paths (/var/folders/…) are not falsely rejected.
#
# RED against current code: renderer proceeds and overwrites progress.md.
# GREEN after fix: renderer warns, exits 0, progress.md unchanged.
# ============================================================================
LEG15_REAL="${TMP_DIR}/leg15-real-root"
LEG15_LINK="${TMP_DIR}/leg15-link-root"
mkdir -p "${LEG15_REAL}/issue-dir"
make_spans "${LEG15_REAL}/issue-dir/trace.jsonl"
cat > "${LEG15_REAL}/issue-dir/progress.md" <<'MD'
# Issue fixture

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
ln -s "$LEG15_REAL" "$LEG15_LINK"
# TRACE_DIR will be leg15-link-root/issue-dir — a real directory, but its
# parent (leg15-link-root) is a symlink.  -L misses this.
BEFORE15="$(cat "${LEG15_REAL}/issue-dir/progress.md")"

RC15=0
STDERR15="$(bash "$RENDERER" "${LEG15_LINK}/issue-dir/trace.jsonl" 2>&1)" || RC15=$?
[ "$RC15" -eq 0 ] \
  || fail "leg15: renderer must exit 0 when trace dir has a symlinked ancestor (warn-never-fail); got exit ${RC15}"

AFTER15="$(cat "${LEG15_REAL}/issue-dir/progress.md")"
[ "$BEFORE15" = "$AFTER15" ] \
  || fail "leg15: progress.md must be unchanged when trace dir logical path traverses a symlink ancestor (real bullet was overwritten)"

printf '%s\n' "$STDERR15" | grep -qi 'symlink\|warn\|redirect\|link\|travers\|ancestor\|component' \
  || fail "leg15: renderer must warn to stderr when trace dir logical path traverses a symlink ancestor"

# ============================================================================
# Leg 16: Mode fault injection — stat or chmod failure → warn + exit 0 + unchanged
#
# Current code swallows failures with '|| true', then mv publishes mktemp's
# 0600 file (16a: stat fails silently; 16b: chmod fails silently).
# Both probes use deterministic fakebins so the test is root-safe.
#
# RED against current code: mv proceeds in both cases (progress.md is changed).
# GREEN after fix: renderer warns, exits 0, progress.md unchanged in both cases.
# ============================================================================

# 16a: stat failure — both stat variants return non-zero, ORIG_PERMS stays
# empty, then mv publishes the mktemp 0600 temp file.
LEG16A="${TMP_DIR}/leg16a"
mkdir -p "${LEG16A}/fakebin"
# Fake stat: always fail regardless of arguments.
cat > "${LEG16A}/fakebin/stat" <<'STATEOF'
#!/usr/bin/env bash
exit 1
STATEOF
chmod +x "${LEG16A}/fakebin/stat"

make_spans "${LEG16A}/trace.jsonl"
cat > "${LEG16A}/progress.md" <<'MD'
# Issue fixture

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
BEFORE16A="$(cat "${LEG16A}/progress.md")"

RC16A=0
STDERR16A="$(PATH="${LEG16A}/fakebin:${PATH}" bash "$RENDERER" "${LEG16A}/trace.jsonl" 2>&1)" \
  || RC16A=$?
[ "$RC16A" -eq 0 ] \
  || fail "leg16a: renderer must exit 0 when stat fails (warn-never-fail); got exit ${RC16A}"

AFTER16A="$(cat "${LEG16A}/progress.md")"
[ "$BEFORE16A" = "$AFTER16A" ] \
  || fail "leg16a: progress.md must be unchanged when stat fails to retrieve permissions (real bullet was overwritten with 0600 temp file)"

printf '%s\n' "$STDERR16A" | grep -qi 'warn\|perm\|stat\|mode\|fail\|retriev' \
  || fail "leg16a: renderer must warn to stderr when stat fails"

# 16b: chmod failure — stat succeeds, chmod on the temp file returns non-zero,
# then mv publishes the temp file with the wrong (mktemp 0600) mode.
LEG16B="${TMP_DIR}/leg16b"
mkdir -p "${LEG16B}/fakebin"
# Fake chmod: always fail (simulate permission denied / read-only filesystem).
cat > "${LEG16B}/fakebin/chmod" <<'CHEOF'
#!/usr/bin/env bash
exit 1
CHEOF
chmod +x "${LEG16B}/fakebin/chmod"

make_spans "${LEG16B}/trace.jsonl"
cat > "${LEG16B}/progress.md" <<'MD'
# Issue fixture

## Action Log

- [conductor] feature_start my-feature pass — real existing bullet
MD
chmod 644 "${LEG16B}/progress.md"
BEFORE16B="$(cat "${LEG16B}/progress.md")"

RC16B=0
STDERR16B="$(PATH="${LEG16B}/fakebin:${PATH}" bash "$RENDERER" "${LEG16B}/trace.jsonl" 2>&1)" \
  || RC16B=$?
[ "$RC16B" -eq 0 ] \
  || fail "leg16b: renderer must exit 0 when chmod fails (warn-never-fail); got exit ${RC16B}"

AFTER16B="$(cat "${LEG16B}/progress.md")"
[ "$BEFORE16B" = "$AFTER16B" ] \
  || fail "leg16b: progress.md must be unchanged when chmod fails to set temp file permissions (real bullet was overwritten)"

printf '%s\n' "$STDERR16B" | grep -qi 'warn\|perm\|chmod\|mode\|fail\|apply' \
  || fail "leg16b: renderer must warn to stderr when chmod fails"

printf 'ok - all legs passed\n'
exit 0
