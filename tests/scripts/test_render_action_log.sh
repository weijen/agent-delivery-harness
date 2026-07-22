#!/usr/bin/env bash
# test_render_action_log.sh — regression sensor for scripts/render-action-log.sh
# (issue #332, feature render-action-log). Covers: path/issue-number/live-worktree
# modes; five core fields; no research suffix; placeholder on no-agent/empty traces;
# missing args/files/heading are warn-never-fail and leave progress unchanged;
# malformed/non-object JSON (array, null, number); ## Action Log / H1+H2 boundaries;
# unreadable/write/stat/chmod failures preserve progress; direct and ancestor symlink
# rejection; permission preservation; TEETH mutation (wrong jq field → no [conductor]).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${ROOT}/scripts/render-action-log.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required to run render-action-log tests"
[ -f "$RENDERER" ] || fail "scripts/render-action-log.sh not found (${RENDERER}) — the Action Log renderer for feature render-action-log (issue #332) is not implemented yet"

# scaffold_progress <dir>: minimal progress.md with ## Action Log + placeholder.
scaffold_progress() { printf '# Issue fixture\n## Action Log\n- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._\n' > "${1}/progress.md"; }

# make_spans <file>: two agent spans (conductor + generator-subagent).
# shellcheck disable=SC1004
make_spans() { printf '%s\n%s\n' \
  '{"schema_version":1,"span":"agent","span_id":"a1","timestamp":"2026-07-01T00:00:00Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"feature_start","harness.feature_id":"render-action-log","harness.outcome":"pass","harness.summary":"selected renderer feature","harness.issue":332}' \
  '{"schema_version":1,"span":"agent","span_id":"a2","timestamp":"2026-07-01T00:00:01Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"red_handback","harness.feature_id":"render-action-log","harness.outcome":"pass","harness.summary":"RED confirmed for right reason","harness.issue":332}' \
  > "$1"; }

# assert_noop <label> <prog> <trace-arg> <stderr-pat>: exit 0, prog unchanged, stderr matches.
assert_noop() {
  local label="$1" prog="$2" arg="$3" pat="$4" before rc stderr
  before="$(cat "$prog")"; rc=0; stderr="$(bash "$RENDERER" "$arg" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "${label}: must exit 0 (warn-never-fail); got ${rc}"
  [ "$(cat "$prog")" = "$before" ] || fail "${label}: progress.md must be unchanged"
  printf '%s\n' "$stderr" | grep -qi "$pat" || fail "${label}: must warn to stderr"
}
# assert_noop_path: like assert_noop with PATH override for fakebin dir ($5).
assert_noop_path() {
  local label="$1" prog="$2" trace="$3" pat="$4" fb="$5" before rc stderr
  before="$(cat "$prog")"; rc=0; stderr="$(PATH="${fb}:${PATH}" bash "$RENDERER" "$trace" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "${label}: must exit 0 (warn-never-fail); got ${rc}"
  [ "$(cat "$prog")" = "$before" ] || fail "${label}: progress.md must be unchanged"
  printf '%s\n' "$stderr" | grep -qi "$pat" || fail "${label}: must warn to stderr"
}
# fakebin <dir> <cmd> <body>: write executable fakebin script.
fakebin() { printf '#!/usr/bin/env bash\n%s\n' "$3" > "${1}/${2}"; chmod +x "${1}/${2}"; }
# git_repo <dir>: init bare repo with one commit.
git_repo() { git -C "$1" init -q -b main; git -C "$1" config user.name T; git -C "$1" config user.email t@t.t; printf 'x\n' > "${1}/README.md"; git -C "$1" add .; git -C "$1" commit -q -m init; }

# --- Leg 1: two agent spans → bullets under ## Action Log (path mode) ---
d="${TMP_DIR}/l1"; mkdir -p "$d"; make_spans "${d}/trace.jsonl"; scaffold_progress "$d"
rc=0; bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "leg1: exit 0"
grep -q -- '^## Action Log$' "${d}/progress.md" || fail "leg1: heading survives"
grep -qF -- '- [conductor] feature_start render-action-log pass — selected renderer feature' "${d}/progress.md" || fail "leg1: first span bullet"
grep -qF -- '- [generator-subagent] red_handback render-action-log pass — RED confirmed for right reason' "${d}/progress.md" || fail "leg1: second span bullet"
al="$(grep -n '^## Action Log$' "${d}/progress.md" | head -1 | cut -d: -f1)"
[ "$(grep -n 'feature_start render-action-log pass' "${d}/progress.md" | head -1 | cut -d: -f1)" -gt "$al" ] \
  || fail "leg1: bullet must appear after heading"
if grep -qF -- '_Record conductor handbacks' "${d}/progress.md"; then
  fail "leg1: placeholder must be replaced"
fi

# --- Leg 2: missing ## Action Log heading → exit 0, unchanged ---
d="${TMP_DIR}/l2"; mkdir -p "$d"; make_spans "${d}/trace.jsonl"
printf '# progress\n\nNo action log section.\n' > "${d}/progress.md"
assert_noop "leg2(missing-heading)" "${d}/progress.md" "${d}/trace.jsonl" 'action.log\|warn\|no.*action\|missing\|heading\|section'

# --- Leg 3: no agent spans → placeholder preserved (empty trace + non-agent-only) ---
d="${TMP_DIR}/l3"; mkdir -p "$d"; printf '' > "${d}/trace.jsonl"; scaffold_progress "$d"
bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null
grep -qF -- '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._' "${d}/progress.md" || fail "leg3: placeholder on empty trace"
d="${TMP_DIR}/l3b"; mkdir -p "$d"; scaffold_progress "$d"
printf '%s\n' '{"schema_version":1,"span":"lifecycle","span_id":"x1","harness.lifecycle_step":"worktree_create","harness.issue":332}' > "${d}/trace.jsonl"
bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null
grep -qF -- '- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._' "${d}/progress.md" || fail "leg3b: placeholder when only non-agent spans"

# --- Leg 4: CLI edge cases — no args; missing trace; issue-number mode ---
rc=0; bash "$RENDERER" 2>/dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "leg4a: no args must exit 0; got ${rc}"
rc=0; stderr="$(bash "$RENDERER" "${TMP_DIR}/nonexistent.jsonl" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "leg4b: missing trace must exit 0; got ${rc}"
printf '%s\n' "$stderr" | grep -qi 'not found\|missing\|warn\|cannot\|no such' || fail "leg4b: must warn for missing trace"
nr="${TMP_DIR}/nr"; mkdir -p "$nr"; git_repo "$nr"
mkdir -p "${nr}/.copilot-tracking/issues/issue-07"; make_spans "${nr}/.copilot-tracking/issues/issue-07/trace.jsonl"
printf '# I7\n## Action Log\n- _placeholder_\n' > "${nr}/.copilot-tracking/issues/issue-07/progress.md"
rc=0; (cd "$nr" && bash "$RENDERER" 7 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] || fail "leg4c: issue-number mode must exit 0; got ${rc}"
grep -qF -- '- [conductor] feature_start' "${nr}/.copilot-tracking/issues/issue-07/progress.md" || fail "leg4c: must render bullets"

# --- Leg 5 (TEETH): mutant renderer wrong jq field → [conductor] absent ---
md="${TMP_DIR}/mutant"; mkdir -p "$md"
sed 's/gen_ai\.agent\.name/harness.lifecycle_step/g' "$RENDERER" > "${md}/render-action-log.sh"
chmod +x "${md}/render-action-log.sh"
d="${TMP_DIR}/l5"; mkdir -p "$d"; make_spans "${d}/trace.jsonl"; scaffold_progress "$d"
bash "${md}/render-action-log.sh" "${d}/trace.jsonl" 2>/dev/null
if grep -qF -- '- [conductor]' "${d}/progress.md"; then
  fail "leg5(TEETH): mutant still produces [conductor] — leg1 assertion would not catch wrong-field extraction"
fi
grep -qF -- '- [feature_start]' "${d}/progress.md" \
  || fail "leg5(TEETH): mutant must produce [feature_start]; mutation may not have applied"

# --- Leg 6: malformed JSON → warn + unchanged ---
d="${TMP_DIR}/l6"; mkdir -p "$d"; printf '{invalid json\n{also broken\n' > "${d}/trace.jsonl"
printf '# p\n## Action Log\n- [conductor] feature_start my-feature pass — existing bullet\n' > "${d}/progress.md"
assert_noop "leg6(malformed-json)" "${d}/progress.md" "${d}/trace.jsonl" 'warn\|parse\|fail\|error\|malform'

# --- Leg 7: unreadable trace → warn + unchanged (skipped as root) ---
if [ "$(id -u)" -eq 0 ]; then
  printf 'note: skipping leg7 (unreadable trace) — running as root\n'
else
  d="${TMP_DIR}/l7"; mkdir -p "$d"
  printf '{"span":"agent","gen_ai.agent.name":"conductor"}\n' > "${d}/trace.jsonl"; chmod 000 "${d}/trace.jsonl"
  printf '# p\n## Action Log\n- [conductor] feature_start my-feature pass — existing bullet\n' > "${d}/progress.md"
  assert_noop "leg7(unreadable-trace)" "${d}/progress.md" "${d}/trace.jsonl" 'warn\|fail\|error\|cannot\|permission\|read\|parse'
fi

# --- Leg 8: ## Action Log Archive not treated as ## Action Log ---
d="${TMP_DIR}/l8"; mkdir -p "$d"; make_spans "${d}/trace.jsonl"
printf '# I\n## Action Log\n- old\n## Action Log Archive\n- archived\n## Other\nother\n' > "${d}/progress.md"
bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null
grep -qF -- '## Action Log Archive' "${d}/progress.md" || fail "leg8: Archive heading must survive"
grep -qF -- '- archived' "${d}/progress.md" || fail "leg8: Archive content must survive"

# --- Leg 9: H1 boundary — # heading after ## Action Log preserved ---
d="${TMP_DIR}/l9"; mkdir -p "$d"; make_spans "${d}/trace.jsonl"
printf '# I\n## Action Log\n- old\n# Final Notes\nImportant final content.\n' > "${d}/progress.md"
bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null
grep -qF -- '# Final Notes' "${d}/progress.md" || fail "leg9: H1 heading must survive"
grep -qF -- 'Important final content.' "${d}/progress.md" || fail "leg9: H1 content must survive"

# --- Leg 10: permissions preserved after atomic replacement ---
d="${TMP_DIR}/l10"; mkdir -p "$d"; make_spans "${d}/trace.jsonl"; scaffold_progress "$d"
chmod 644 "${d}/progress.md"; bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null
perms="$(stat -c '%a' "${d}/progress.md" 2>/dev/null || stat -f '%OLp' "${d}/progress.md" 2>/dev/null || true)"
[ "$perms" = "644" ] || fail "leg10: permissions must be preserved; expected 644, got '${perms}'"

# --- Leg 11: bullets write failure → warn + unchanged (root-safe via dir target) ---
# Fake mktemp converts render-bullets target to a dir; printf→dir fails even as root.
REAL_MKTEMP="$(command -v mktemp)"
d="${TMP_DIR}/l11"; mkdir -p "${d}/fb"; fakebin "${d}/fb" chmod 'exit 0'
cat > "${d}/fb/mktemp" <<MKEOF
#!/usr/bin/env bash
r="\$("${REAL_MKTEMP}" "\$@")" || exit \$?
for a in "\$@"; do last="\$a"; done
case "\$last" in *render-bullets*) rm -f "\$r"; mkdir "\$r" ;; esac
printf '%s\n' "\$r"
MKEOF
chmod +x "${d}/fb/mktemp"
make_spans "${d}/trace.jsonl"; scaffold_progress "$d"
assert_noop_path "leg11(bullets-write-fail)" "${d}/progress.md" "${d}/trace.jsonl" 'warn\|fail\|write\|bullet\|temp' "${d}/fb"

# --- Leg 12: live layout — issue-number mode finds worktree progress.md ---
mr="${TMP_DIR}/mr12"; wt="${TMP_DIR}/wt12"; mkdir -p "$mr"; git_repo "$mr"
git -C "$mr" worktree add -q "$wt" -b leg12
mkdir -p "${mr}/.copilot-tracking/issues/issue-12"; make_spans "${mr}/.copilot-tracking/issues/issue-12/trace.jsonl"
mkdir -p "${wt}/.copilot-tracking/issues/issue-12"
printf '# I12\n## Action Log\n- _placeholder_\n' > "${wt}/.copilot-tracking/issues/issue-12/progress.md"
rc=0; (cd "$wt" && bash "$RENDERER" 12 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] || fail "leg12: live-layout must exit 0; got ${rc}"
grep -qF -- '- [conductor] feature_start render-action-log pass' \
  "${wt}/.copilot-tracking/issues/issue-12/progress.md" || fail "leg12: must render bullets into worktree progress.md"

# --- Leg 13: symlink rejection — progress.md symlink (13a) and trace dir symlink (13b) ---
da="${TMP_DIR}/l13a"; dt="${TMP_DIR}/l13a-t"; mkdir -p "$da" "$dt"; make_spans "${da}/trace.jsonl"
printf '# p\n## Action Log\n- _placeholder_\n' > "${dt}/real.md"; ln -s "${dt}/real.md" "${da}/progress.md"
assert_noop "leg13a(symlink-progress)" "${dt}/real.md" "${da}/trace.jsonl" 'symlink\|warn\|redirect\|link'
db="${TMP_DIR}/l13b-real"; mkdir -p "$db"; make_spans "${db}/trace.jsonl"; scaffold_progress "$db"
ln -s "$db" "${TMP_DIR}/l13b-link"
assert_noop "leg13b(symlink-dir)" "${db}/progress.md" "${TMP_DIR}/l13b-link/trace.jsonl" 'symlink\|warn\|redirect\|link'

# --- Leg 14: non-object JSON (array, null, number) → warn + unchanged (table-driven) ---
for noval in '[]' 'null' '42'; do
  d="${TMP_DIR}/l14-${noval//[^a-z0-9]/-}"; mkdir -p "$d"
  printf '%s\n' "$noval" > "${d}/trace.jsonl"
  printf '# p\n## Action Log\n- [conductor] feature_start my-feature pass — real existing bullet\n' > "${d}/progress.md"
  assert_noop "leg14(${noval})" "${d}/progress.md" "${d}/trace.jsonl" 'warn\|parse\|fail\|error\|object\|non-object\|json'
done

# --- Leg 15: ancestor symlink → trace dir logical path traverses symlink → warn + unchanged ---
dr="${TMP_DIR}/l15-real"; mkdir -p "${dr}/issue-dir"; make_spans "${dr}/issue-dir/trace.jsonl"
printf '# p\n## Action Log\n- [conductor] feature_start my-feature pass — real existing bullet\n' > "${dr}/issue-dir/progress.md"
ln -s "$dr" "${TMP_DIR}/l15-link"
assert_noop "leg15(ancestor-symlink)" "${dr}/issue-dir/progress.md" "${TMP_DIR}/l15-link/issue-dir/trace.jsonl" \
  'symlink\|warn\|redirect\|link\|travers\|ancestor\|component'

# --- Leg 16: mode fault injection (stat fail, chmod fail) → warn + unchanged (table-driven) ---
for fault in stat chmod; do
  d="${TMP_DIR}/l16-${fault}"; mkdir -p "${d}/fb"; fakebin "${d}/fb" "$fault" 'exit 1'
  make_spans "${d}/trace.jsonl"
  printf '# p\n## Action Log\n- [conductor] feature_start my-feature pass — real existing bullet\n' > "${d}/progress.md"
  assert_noop_path "leg16(${fault}-fail)" "${d}/progress.md" "${d}/trace.jsonl" \
    'warn\|perm\|stat\|mode\|fail\|chmod\|retriev\|apply' "${d}/fb"
done

# --- Leg 17: research-field span → core five-field bullet only (no research suffix) ---
d="${TMP_DIR}/l17"; mkdir -p "$d"; scaffold_progress "$d"
printf '%s\n' '{"schema_version":1,"span":"agent","span_id":"r1","timestamp":"2026-07-01T00:00:00Z","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"some-research-feature","harness.outcome":"pass","harness.summary":"completed with research","harness.issue":332,"harness.research_url":"https://example.com/doc","harness.research_summary":"consulted docs page"}' > "${d}/trace.jsonl"
bash "$RENDERER" "${d}/trace.jsonl" 2>/dev/null
grep -qF -- '- [generator-subagent] green_handback some-research-feature pass — completed with research' \
  "${d}/progress.md" || fail "leg17: research span must render core five-field bullet"
if grep -q 'research:' "${d}/progress.md"; then
  fail "leg17: must not add a research: annotation — Action Log is core five fields only"
fi

printf 'ok - all legs passed\n'
