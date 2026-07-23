#!/usr/bin/env bash
# test_trace_gate.sh — regression + e2e sensor for the consolidated trace gate
# (issue #103, feature trace-gate-two-phase, plan Phase 4).
#
# Executable spec. The gate follows the two established precedents: the #84
# status-doc rollout (land as a review-gate.sh subcommand, wire into check)
# and REQUIRE_FEATURES_COMPLETE (documented env flag flips warn → hard fail;
# default stays warn).
#
#   1. `review-gate.sh trace` runs check-trace-consistency.sh for the current issue (branch-resolved,
#      like every other subcommand; artifact set at the MAIN checkout root).
#      Findings present → they are PRINTED (passed through, so the operator
#      sees rule names from the checker) plus a warning summary,
#      and the exit code stays 0 (warn-only default). Under
#      REQUIRE_TRACE_CONSISTENCY=1 the same findings are printed and the
#      exit code is 1 (blocking). A clean trace exits 0 in BOTH modes.
#   2. Wiring: `review-gate.sh check` additionally runs the trace gate
#      warn-only — its own exit semantics are UNCHANGED by trace findings in
#      default mode (approval + status-doc still decide), but the findings
#      appear in its output; under REQUIRE_TRACE_CONSISTENCY=1 findings make
#      check exit non-zero. finish-issue.sh runs the gate before teardown:
#      warn-only default (worktree still removed, findings printed);
#      REQUIRE_TRACE_CONSISTENCY=1 + findings → non-zero exit AND the
#      worktree is LEFT INTACT (mirrors the REQUIRE_FEATURES_COMPLETE
#      pattern: the flag turns the warning into a refusal before
#      worktree_remove).
#   3. The gate emits ONE tool span per `trace` run:
#      gen_ai.tool.name=review-gate.trace with harness.outcome (pass when
#      the gate exits 0, fail when blocking fired) and NUMERIC finding
#      counts harness.violation_count / harness.warning_count from that
#      checker. Self-clean obligation: the gate's own
#      spans must not create new checker findings (checker run
#      after clean-fixture gate runs still exits 0 — numeric count keys must
#      be added to the validator's known-key type map coherently).
#   4. Contract presence backstop (docs/harness-contract.yml): the
#      REQUIRE_TRACE_CONSISTENCY promotion flag is documented, the trace
#      gate is declared with `mode: warn` (record id containing
#      trace-consistency), and the review-gate.trace tool span is declared.
#      (test_harness_contract.sh's generic record checks then guard the
#      entries against silent deletion; only the presence pin lives here.)
#
# Fixture style: throwaway MAIN repos + linked issue worktrees built by the
# REAL start-issue.sh (SKIP_INIT=1, fake gh), pinned PATH — the pattern of
# test_trace_finish_issue.sh / test_trace_review_gate.sh. The consistency
# artifact set (progress.md, feature_list.json) is planted at the MAIN root
# issue dir (the plan's "main-root artifact set"). Dirty fixtures plant one
# schema finding (a non-JSON trace line → invalid_json) AND one cross-artifact
# finding (a rogue-role agent span → role_attribution_gap; log_without_span /
# span_without_log are retired, issue #332) so the output proves the single
# consolidated checker (#335) owns both rule families.
#
# RED status at authoring time: `review-gate.sh trace` does not exist
# (unknown subcommand → usage + exit 1), neither script is wired, no
# review-gate.trace span is emitted, and the contract has no trace-gate
# entries.
#
# Loop-2 addition (#103 review F1, 2026-07-04): fixture F4 — the REAL
# layout, where progress.md/feature_list.json live only in the WORKTREE
# tracking dir (start-issue scaffolds them there; the main root holds only
# trace.jsonl). The gate's consistency half must be LIVE there: findings
# are surfaced and the output carries NO "consistency half skipped" note.
# RED against the shipped gate (the checker's issue mode exited 2 on the
# real layout, so the gate skipped the consistency half — exactly what the
# F1/F2/F3 main-root fixtures masked).
#
# Exit codes: 0 trace-gate contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT_YML="${ROOT}/docs/harness-contract.yml"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE \
  REQUIRE_TRACE_CONSISTENCY FORCE DELETE_BRANCH 2>/dev/null || true
# Hermeticity (issue #329): finish-issue.sh closeout now joins native Copilot
# economics from ${COPILOT_CLI_STATE_ROOT}/<session>/events.jsonl. Pin the root
# to an isolated empty dir and unset the ambient session id so this fixture's
# assertions never read the real developer ~/.copilot session state.
unset COPILOT_AGENT_SESSION_ID 2>/dev/null || true
export COPILOT_CLI_STATE_ROOT="${TMP_DIR}/native-empty"

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the gate and this sensor are jq-driven)"
[ -f "$SCHEMA" ] || hard_fail "trace schema contract not found (${SCHEMA})"
[ -f "$CONTRACT_YML" ] || hard_fail "harness contract not found (${CONTRACT_YML})"
for s in review-gate.sh finish-issue.sh finish-lib.sh check-trace-consistency.sh \
         trace-lib.sh trace-report.sh issue-lib.sh start-issue.sh check-feature-list.sh \
         ci-coverage-lib.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found — required by the trace-gate fixture"
done

# --- Pinned PATH + fake gh (network-free, login-free) ---------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${BIN}/gh"

# --- Fixture builder --------------------------------------------------------------
# make_gate_fixture <dir> <issue>: MAIN repo (all lifecycle scripts + schema
# contract at canonical paths) + worktree created by the REAL start-issue.sh,
# then the consistency artifact set planted at the MAIN root issue dir:
# progress.md with an empty Action Log and a feature_list with no passes:true
# claims — a CLEAN baseline (the start-issue spans are lifecycle spans, so
# the agent-span/bullet multisets are both empty and every state rule skips
# or holds).
make_gate_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh \
           review-gate.sh trace-lib.sh check-trace-consistency.sh trace-report.sh \
           ci-coverage-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "$SCHEMA" "${dir}/docs/evaluation/trace-schema.v1.json"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '/.worktrees/\n.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out" >&2; hard_fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}/.worktrees/issue-${pad}" ] \
    || hard_fail "setup: worktree for issue ${issue} was not created"
  [ -f "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" ] \
    || hard_fail "setup: start-issue emitted no main-root trace for issue ${issue}"
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  printf '{"issue":%s,"features":[{"id":"feat-a","title":"A","steps":[],"passes":false}]}\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

# dirty_gate_fixture <dir> <issue>: ONE schema finding (non-JSON trace
# line → invalid_json) + ONE consistency finding (rogue-role agent span →
# role_attribution_gap). log_without_span / span_without_log are retired
# (issue #332); both families are owned by the consolidated checker (#335).
dirty_gate_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  printf 'GATE_FIXTURE_NOT_JSON {\n' \
    >> "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"
  printf '{"schema_version":1,"timestamp":"2026-07-06T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"rogue-role","harness.lifecycle_step":"deviation","harness.feature_id":"-","harness.outcome":"blocked"}\n' \
    "$issue" >> "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl"
}

# last review-gate.trace tool span in a trace file (tolerates the planted
# non-JSON line).
last_gate_span() {
  jq -nRr '[inputs | fromjson?
            | select(.span == "tool" and .["gen_ai.tool.name"] == "review-gate.trace")]
           | if length == 0 then "" else (last | tostring) end' < "$1"
}

OUT="${TMP_DIR}/out.txt"
run_in() { # run_in <dir> <out> <env...> -- <cmd...>
  local dir="$1" out="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local rc=0
  (cd "$dir" && env PATH="$BIN" ${envs[@]+"${envs[@]}"} "$@") > "$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# ============================================================================
# Fixture F1 (issue 80): trace subcommand + tool span + check wiring
# ============================================================================
F1="${TMP_DIR}/f80"
make_gate_fixture "$F1" 80
WT1="${F1}/.worktrees/issue-80"
TRACE1="${F1}/.copilot-tracking/issues/issue-80/trace.jsonl"

# --- 1a. CLEAN trace: `trace` exits 0 in BOTH modes -------------------------------
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "clean trace, default: 'review-gate.sh trace' must exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
rc="$(run_in "$WT1" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 -- ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "clean trace, blocking flag: exit must stay 0 when there are no findings, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"

# --- 3a. Self-clean: the gate's own spans create no checker findings --------------
span="$(last_gate_span "$TRACE1")"
[ -n "$span" ] \
  || fail "clean trace: no review-gate.trace tool span emitted (feature trace-gate-two-phase not instrumented)"
rc=0
(cd "$WT1" && env PATH="$BIN" ./scripts/check-trace-consistency.sh 80) > "$OUT" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "self-clean: check-trace-consistency.sh must accept the trace AFTER gate runs (the gate's own spans — incl. numeric finding counts — must not be schema/type violations), got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"

# --- 1b. DIRTY trace: warn-only default -------------------------------------------
dirty_gate_fixture "$F1" 80
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "dirty trace, default: warn-only — exit must stay 0 with findings, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'invalid_json' "$OUT" \
  || fail "dirty trace, default: validator finding (invalid_json) must be printed — validate-trace.sh not run/surfaced (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'role_attribution_gap' "$OUT" \
  || fail "dirty trace, default: consistency finding (role_attribution_gap) must be printed — check-trace-consistency.sh not run/surfaced (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'warn|⚠' "$OUT" \
  || fail "dirty trace, default: a warning summary is required (warn-only phase must SAY it is warning; output: $(tr '\n' '|' < "$OUT"))"

# --- 3b. Tool span for the warn-only run: pass + aggregated numeric counts --------
span="$(last_gate_span "$TRACE1")"
[ -n "$span" ] \
  || fail "dirty trace, default: no review-gate.trace tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "pass")
      and ((.["harness.violation_count"] | type) == "number")
      and (.["harness.violation_count"] >= 2)
      and ((.["harness.warning_count"] | type) == "number")
      and (.["harness.warning_count"] >= 0)' >/dev/null 2>&1 \
    || fail "dirty trace, default: review-gate.trace span must carry harness.outcome=pass (gate exited 0) and NUMERIC harness.violation_count>=2 from the single checker / harness.warning_count>=0: ${span}"
fi

# --- 1c. DIRTY trace: REQUIRE_TRACE_CONSISTENCY=1 blocks --------------------------
rc="$(run_in "$WT1" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 -- ./scripts/review-gate.sh trace)"
[ "$rc" = "1" ] \
  || fail "dirty trace, blocking flag: exit must be 1, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'role_attribution_gap' "$OUT" \
  || fail "dirty trace, blocking flag: findings must still be printed when blocking (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_gate_span "$TRACE1")"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "fail")
      and ((.["harness.violation_count"] | type) == "number")
      and (.["harness.violation_count"] >= 2)' >/dev/null 2>&1 \
    || fail "dirty trace, blocking flag: review-gate.trace span must carry harness.outcome=fail and the numeric counts: ${span}"
else
  fail "dirty trace, blocking flag: no review-gate.trace tool span emitted"
fi

# --- 2a. `check` wiring: default exit semantics unchanged, findings surfaced ------
# Fresh approval + status-doc satisfied, trace findings present.
printf '# Progress\n\nissue-80 work\n' > "${WT1}/docs/PROGRESS.md"
git -C "$WT1" add docs/PROGRESS.md
git -C "$WT1" commit -q -m "issue-80: progress update"
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] || hard_fail "setup: review-gate approve failed in F1 (output: $(tr '\n' '|' < "$OUT"))"
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh check)"
[ "$rc" = "0" ] \
  || fail "check, default: trace findings must NOT change check's exit semantics (approval + status-doc pass), got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'role_attribution_gap' "$OUT" \
  || fail "check, default: the warn-only trace gate must run inside check and surface its findings (output: $(tr '\n' '|' < "$OUT"))"
rc="$(run_in "$WT1" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check, blocking flag: trace findings must fail check under REQUIRE_TRACE_CONSISTENCY=1 (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Fixture F2 (issue 81): finish-issue wiring, warn-only default
# ============================================================================
F2="${TMP_DIR}/f81"
make_gate_fixture "$F2" 81
dirty_gate_fixture "$F2" 81
rc="$(run_in "$F2" "$OUT" ABANDONED=1 -- ./scripts/finish-issue.sh 81 SLUG=fixture)"
[ "$rc" = "0" ] \
  || fail "finish, default: warn-only — finish-issue.sh must still exit 0 with trace findings, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'role_attribution_gap' "$OUT" \
  || fail "finish, default: the trace gate must run before teardown and surface findings (output: $(tr '\n' '|' < "$OUT"))"
[ ! -e "${F2}/.worktrees/issue-81" ] \
  || fail "finish, default: worktree must still be removed in warn-only mode (REQUIRE_FEATURES_COMPLETE precedent)"

# ============================================================================
# Fixture F3 (issue 82): finish-issue wiring, blocking flag leaves worktree
# ============================================================================
F3="${TMP_DIR}/f82"
make_gate_fixture "$F3" 82
dirty_gate_fixture "$F3" 82
rc="$(run_in "$F3" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 -- ./scripts/finish-issue.sh 82 SLUG=fixture)"
[ "$rc" != "0" ] \
  || fail "finish, blocking flag: trace findings must refuse the finish under REQUIRE_TRACE_CONSISTENCY=1, got exit 0 (output: $(tr '\n' '|' < "$OUT"))"
[ -d "${F3}/.worktrees/issue-82" ] \
  || fail "finish, blocking flag: the worktree must be LEFT INTACT when the gate blocks (refusal happens before worktree_remove)"

# ============================================================================
# Fixture F4 (issue 83): REAL layout — worktree-local artifacts, consistency
# half LIVE (loop-2 review F1)
# ============================================================================
F4="${TMP_DIR}/f83"
make_gate_fixture "$F4" 83
WT4="${F4}/.worktrees/issue-83"
# Strip the main-root copies make_gate_fixture planted: live runs keep only
# trace.jsonl at the main root; progress.md/feature_list.json are the
# start-issue-scaffolded WORKTREE ones.
rm "${F4}/.copilot-tracking/issues/issue-83/progress.md" \
   "${F4}/.copilot-tracking/issues/issue-83/feature_list.json"
[ -f "${WT4}/.copilot-tracking/issues/issue-83/progress.md" ] \
  || hard_fail "F4 setup: start-issue did not scaffold the worktree progress.md"
# Consistency-only finding via main-root trace: a rogue-role span →
# role_attribution_gap (log_without_span retired, issue #332). The checker
# still reads the worktree-local feature_list.json via the real-layout
# fallback path, proving the consistency half is LIVE.
printf '{"schema_version":1,"timestamp":"2026-07-06T12:10:00Z","span":"agent","harness.issue":83,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"rogue-role","harness.lifecycle_step":"deviation","harness.feature_id":"-","harness.outcome":"blocked"}\n' \
  >> "${F4}/.copilot-tracking/issues/issue-83/trace.jsonl"
rc="$(run_in "$WT4" "$OUT" -- ./scripts/review-gate.sh trace)"
[ "$rc" = "0" ] \
  || fail "real layout: warn-only default must exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
if grep -q 'consistency half skipped' "$OUT"; then
  fail "real layout: the consistency half must be LIVE when artifacts are worktree-local — 'consistency half skipped' means the checker never saw the real layout (output: $(tr '\n' '|' < "$OUT"))"
fi
grep -q 'role_attribution_gap' "$OUT" \
  || fail "real layout: the consistency finding (role_attribution_gap) must be surfaced by the gate (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Fixture F5 (issue 84): trace-only findings survive missing cross-artifacts
# ============================================================================
F5="${TMP_DIR}/f84"
make_gate_fixture "$F5" 84
WT5="${F5}/.worktrees/issue-84"
TRACE5="${F5}/.copilot-tracking/issues/issue-84/trace.jsonl"
rm "${F5}/.copilot-tracking/issues/issue-84/progress.md" \
  "${WT5}/.copilot-tracking/issues/issue-84/progress.md"
printf 'GATE_FIXTURE_NOT_JSON {\n' >> "$TRACE5"
rc="$(run_in "$WT5" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 -- \
  ./scripts/review-gate.sh trace)"
[ "$rc" = "1" ] \
  || fail "missing progress: trace findings must still block under REQUIRE_TRACE_CONSISTENCY=1, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'invalid_json' "$OUT" \
  || fail "missing progress: trace-only findings must be preserved when consistency cannot run (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_gate_span "$TRACE5")"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "fail")
      and (.["harness.violation_count"] >= 1)' >/dev/null 2>&1 \
    || fail "missing progress: gate span must count the preserved finding and fail: ${span}"
else
  fail "missing progress: trace gate must emit a finding-count span"
fi

# ============================================================================
# 4. Contract presence backstop (docs/harness-contract.yml)
# ============================================================================
grep -q 'REQUIRE_TRACE_CONSISTENCY' "$CONTRACT_YML" \
  || fail "contract: the REQUIRE_TRACE_CONSISTENCY promotion flag must be documented in docs/harness-contract.yml"
if ! grep -A5 'id: .*trace-consistency' "$CONTRACT_YML" | grep -q 'mode: warn'; then
  fail "contract: a trace-consistency gate with 'mode: warn' must be declared (warn-only phase one, promotion via the documented flag)"
fi
grep -q 'review-gate\.trace' "$CONTRACT_YML" \
  || fail "contract: the review-gate.trace verdict span must be declared"

# --- Result -------------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-gate-two-phase contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-gate-two-phase contract honored\n'
