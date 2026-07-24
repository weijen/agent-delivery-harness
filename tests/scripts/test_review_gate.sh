#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts create-pr.sh,review-gate.sh
TMP_DIR="$FIXTURE_TMP_DIR"
REPO="$FIXTURE_REPO"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# This sensor drives one long, sequentially-mutated git repo, so scenarios share
# state in a single shell. fail() records a diagnostic and marks the current
# scenario failed WITHOUT aborting; emit() turns that mark into exactly one TAP
# row and resets it. Unconditional setup steps between scenarios still run under
# `set -e`, so a failed assertion never fail-fasts yet the state chain is
# preserved. Exit semantics: all scenarios pass => tap_done exits 0.
_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

make_commit() {
  local message="$1"
  local tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref refs/heads/feature/review-gate "$commit"
  git reset -q --hard "$commit"
}

write_fake_gh() {
  mkdir -p "${TMP_DIR}/bin"
  cat > "${TMP_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1 $2" = "pr view" ]; then
  # Real gh returns the PR number once the PR exists; model that so the
  # create-pr.sh "unresolvable PR number" guard (issue #90) is satisfied.
  [ -n "${GH_LOG:-}" ] && [ -f "${GH_LOG}.created" ] || exit 1
  printf '123\n'
  exit 0
fi

if [ "$1 $2" = "pr create" ]; then
  printf '%s\n' "$*" >> "${GH_LOG:?}"
  : > "${GH_LOG}.created"
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
  chmod +x "${TMP_DIR}/bin/gh"
}

setup_origin_main() {
  fixture_repo --with-scripts create-pr.sh,review-gate.sh
  ORIGIN_WORK="$FIXTURE_REPO"
  mkdir -p "${ORIGIN_WORK}/docs"
  printf '# Progress\n\nbaseline\n' > "${ORIGIN_WORK}/docs/PROGRESS.md"
  git -C "$ORIGIN_WORK" add docs/PROGRESS.md
  git -C "$ORIGIN_WORK" commit -q -m "add progress baseline"
  git clone -q --bare "$ORIGIN_WORK" "${TMP_DIR}/origin.git"
  git -C "$ORIGIN_WORK" remote add origin "${TMP_DIR}/origin.git"
  git remote add origin "${TMP_DIR}/origin.git"
  git fetch -q origin main
}

add_origin_main_commit() {
  local filename="$1"
  local content="$2"
  printf '%s\n' "$content" > "${ORIGIN_WORK}/${filename}"
  git -C "$ORIGIN_WORK" add "$filename"
  git -C "$ORIGIN_WORK" commit -q -m "main update ${filename}"
  git -C "$ORIGIN_WORK" push -q origin main
}

cd "$REPO"
printf 'initial\n' > README.md
mkdir -p docs
printf '# Progress\n\nbaseline\n' > docs/PROGRESS.md
git add .gitignore README.md docs/PROGRESS.md scripts/create-pr.sh scripts/review-gate.sh
git commit -q -m "add progress baseline"
git checkout -q -b feature/review-gate

printf '# Progress\n\ninitial feature work\n' > docs/PROGRESS.md
git add docs/PROGRESS.md
make_commit "initial"

if ./scripts/review-gate.sh check >/tmp/review-gate-check.out 2>&1; then
  fail "check passed without approval"
fi
grep -q "current HEAD has not been approved" /tmp/review-gate-check.out || fail "missing unapproved HEAD message"
emit "review-gate check fails on an unapproved HEAD"

./scripts/review-gate.sh approve >/tmp/review-gate-approve.out
./scripts/review-gate.sh check >/tmp/review-gate-check.out
grep -q "review approved for current HEAD" /tmp/review-gate-check.out || fail "approval check did not pass"
emit "review-gate check passes after approving the current HEAD"

# NB: root *.md would now legitimately carry the approval (docs-only carry,
# 2026-07-22) — move HEAD with a SCRIPT change so stale-head still triggers.
printf '# changed\n' >> scripts/probe.sh 2>/dev/null || printf '#!/usr/bin/env bash\n' > scripts/probe.sh
git add scripts/probe.sh
make_commit "change head"

if ./scripts/review-gate.sh check >/tmp/review-gate-stale.out 2>&1; then
  fail "check passed after HEAD changed"
fi
grep -q "current HEAD has not been approved" /tmp/review-gate-stale.out || fail "missing stale approval message"
emit "review-gate check fails after HEAD moves past the approval"

if ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr.out 2>&1; then
  fail "create-pr passed without current HEAD approval"
fi
grep -q "current HEAD has not been approved" /tmp/create-pr.out || fail "create-pr did not stop at review gate"
emit "create-pr refuses without current-HEAD approval"

write_fake_gh
export PATH="${TMP_DIR}/bin:${PATH}"
export GH_LOG="${TMP_DIR}/gh.log"
ORIGIN_WORK=""
setup_origin_main

git reset -q --hard origin/main
printf 'feature\n' > feature.txt
printf '# Progress\n\nphase B feature\n' > docs/PROGRESS.md
git add feature.txt docs/PROGRESS.md
make_commit "feature commit"
approved_head="$(git rev-parse HEAD)"
./scripts/review-gate.sh approve >/tmp/review-gate-approved-feature.out

if ! ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr-unchanged-sync.out 2>&1; then
  fail "create-pr refused approved HEAD when sync did not change it"
fi
current_head="$(git rev-parse HEAD)"
[ "$current_head" = "$approved_head" ] || fail "unchanged sync rewrote approved HEAD"
[ -s "$GH_LOG" ] || fail "create-pr did not open PR after unchanged sync"
emit "create-pr opens a PR on an approved HEAD when sync does not change it"

git reset -q --hard "$approved_head"
git push -q origin :feature/review-gate >/dev/null 2>&1 || true
: > "$GH_LOG"
rm -f "${GH_LOG}.created"
add_origin_main_commit "main.txt" "main advanced"

# Issue #310: a content-preserving rebase carries the approval forward via
# patch-id identity — no fresh approve needed. The PR must open on the
# first try after the rebase.
if ! ./scripts/create-pr.sh --title "test" --body "test" >/tmp/create-pr-stale-after-sync.out 2>&1; then
  fail "create-pr must succeed after content-preserving rebase (carry approval — issue #310)"
fi
# Independently assert the PR opened via the GH_LOG (the fake gh pr create writes
# to it). Do not rely on carry-diagnostic text being present in output — that
# diagnostic is an implementation detail, not the observable contract.
[ -s "$GH_LOG" ] \
  || { cat /tmp/create-pr-stale-after-sync.out; fail "create-pr did not open PR after content-preserving rebase (carry approval — issue #310)"; }
emit "create-pr carries approval across a content-preserving rebase (issue #310)"

tap_done
(
cd "$ROOT"

TMP_DIR="${ROOT}/.copilot-tracking/test-tmp/review-gate-resolve-$$"
mkdir -p "$TMP_DIR"
export TMPDIR="${TMP_DIR}/system-tmp"
mkdir -p "$TMPDIR"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
hard_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

unset TRACE_ISSUE REQUIRE_LOG_COMPLETE 2>/dev/null || true
GATE="${ROOT}/scripts/review-gate.sh"
[ -x "$GATE" ] || hard_fail "scripts/review-gate.sh not found or not executable"

# --- Tooth 1: single resolution implementation -------------------------------
# The anchored branch pattern is the fingerprint of the resolution block.
block_count="$(grep -cE '\^feature/issue-\(\[0-9\]\+\)-|\^feature/issue-\(\[0-9\]\+\)' "$GATE" || true)"
if [ "$block_count" -ne 1 ]; then
  fail "review-gate.sh must resolve the issue in ONE helper; found ${block_count} branch-resolution blocks (expected 1)"
fi

# --- Behavioral fixtures -----------------------------------------------------
make_repo() {
  local work branch="$1"
  work="$(mktemp -d "${TMP_DIR}/work.XXXXXX")"
  rm -rf "$work"
  git clone -q "$REPO" "$work"
  git -C "$work" remote remove origin
  git -C "$work" config user.email t@t
  git -C "$work" config user.name t
  git -C "$work" checkout -q -B "$branch"
  printf '%s' "$work"
}

seed_progress() {
  local work="$1" nn="$2" dir
  dir="${work}/.copilot-tracking/issues/issue-${nn}"
  mkdir -p "$dir"
  cat > "${dir}/progress.md" <<EOF
# Issue ${nn} progress

## Verify gate
- [test-subagent] red_handback demo pass — sensor created.
EOF
}

run_gate() {
  local work="$1"; shift
  (cd "$work" && env "$@" "$GATE" log-completeness 2>&1) || true
}

# Case A: branch feature/issue-42-* (no TRACE_ISSUE) resolves 42.
work_a="$(make_repo feature/issue-42-demo-slug)"
seed_progress "$work_a" 42
out_a="$(run_gate "$work_a")"
grep -Eq 'issue 42\b' <<<"$out_a" \
  || fail "branch source: expected resolution of issue 42, got: ${out_a}"

# Case B: TRACE_ISSUE env resolves 99 regardless of branch.
work_b="$(make_repo main)"
seed_progress "$work_b" 99
out_b="$(run_gate "$work_b" TRACE_ISSUE=99)"
grep -Eq 'issue 99\b' <<<"$out_b" \
  || fail "env source: expected resolution of issue 99, got: ${out_b}"

# TRACE_ISSUE follows trace-lib's digits-only, de-padded contract.
out_b_padded="$(run_gate "$work_b" TRACE_ISSUE=00099)"
grep -Eq 'issue 99\b' <<<"$out_b_padded" \
  || fail "padded env source: expected de-padded issue 99, got: ${out_b_padded}"
if grep -Eq 'issue 00099\b' <<<"$out_b_padded"; then
  fail "TRACE_ISSUE must be de-padded before gate use"
fi

out_b_invalid="$(run_gate "$work_b" TRACE_ISSUE='../99')"
grep -qiE 'cannot resolve the issue number|must be a positive integer' <<<"$out_b_invalid" \
  || fail "invalid TRACE_ISSUE must be rejected as unresolvable, got: ${out_b_invalid}"
if grep -Fq 'issue ../99' <<<"$out_b_invalid"; then
  fail "invalid TRACE_ISSUE must never be forwarded to gate paths"
fi

# Case C: worktree basename issue-55 resolves 55 (no branch match, no env).
work_c_parent="$(mktemp -d "${TMP_DIR}/wtc.XXXXXX")"
work_c="${work_c_parent}/issue-55"
git clone -q "$REPO" "$work_c"
git -C "$work_c" remote remove origin
git -C "$work_c" config user.email t@t
git -C "$work_c" config user.name t
seed_progress "$work_c" 55
out_c="$(run_gate "$work_c")"
grep -Eq 'issue 55\b' <<<"$out_c" \
  || fail "basename source: expected resolution of issue 55, got: ${out_c}"

# Case D: precedence — TRACE_ISSUE wins over a feature/issue-* branch.
work_d="$(make_repo feature/issue-42-demo-slug)"
seed_progress "$work_d" 7
out_d="$(run_gate "$work_d" TRACE_ISSUE=7)"
grep -Eq 'issue 7\b' <<<"$out_d" \
  || fail "precedence: TRACE_ISSUE=7 must win over branch issue-42, got: ${out_d}"

# Case E: unresolvable context skips gracefully (no crash, no guess).
work_e="$(make_repo main)"
out_e="$(run_gate "$work_e")"
grep -Eiq 'cannot resolve the issue number|skipped' <<<"$out_e" \
  || fail "unresolvable: expected a graceful skip, got: ${out_e}"

if [ "$fails" -ne 0 ]; then
  printf '\n%d review-gate resolution contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'review-gate issue-resolution helper contract honored\n'
)

(
cd "$ROOT"

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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_TRACE_CONSISTENCY \
  REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE REVIEW_GATE_APPROVE_PHASE \
  2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (check-trace-consistency and this sensor are jq-driven)"
for s in review-gate.sh check-trace-consistency.sh \
         trace-lib.sh issue-lib.sh; do
  [ -x "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found or not executable — required by the verdict PR-gate fixture"
done

# --- Pinned PATH --------------------------------------------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    if [ -n "$p" ]; then
      ln -sf "$p" "${dir}/${t}"
    fi
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false

# --- Fixture builder ----------------------------------------------------------
# make_repo <dir> <issue>: a single git repo carrying review-gate.sh + deps at
# scripts/, a `main` baseline, then a feature/issue-NN-* branch with a
# docs/PROGRESS.md change committed as inert historical fixture data. Plants a
# main-root issue dir with an empty Action Log progress.md
# and a feat-a passes:true feature list carrying a governed teeth_proof_waiver
# (so red_first_evidence_gate is satisfied and the verdict leg is the only
# blocking gate). Per-case setup appends spans/bullets and/or a trace file.
make_repo() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  git clone -q "$REPO" "$dir"
  git -C "$dir" remote remove origin
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in review-gate.sh check-trace-consistency.sh \
           trace-lib.sh issue-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/"
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs scripts
  git -C "$dir" commit -q -m "add review fixture"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$issue" > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "issue-${issue}: progress update"
  local idir="${dir}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$idir"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${idir}/progress.md"
  # feat-a passes:true with a governed teeth_proof_waiver: teeth_proof_missing
  # and feature_start_missing are pre-satisfied, so red_first_evidence_gate
  # passes and the verdict leg is the only blocking gate under test.
  jq -nc --argjson issue "$issue" '
    {issue: $issue,
     features: [{
       id: "feat-a", title: "A", passes: true,
       teeth_proof_waiver: {kind: "justified",
         reason: "fixture waiver so red-first passes and the verdict gate is the only variable"}
     }]}' > "${idir}/feature_list.json"
}

# add_green <idir> <issue> <fid>: append one schema-shaped green_handback agent
# span (clears unverified_feature_pass so review_verdict_missing is the sole
# feature-scoped VIOLATION) plus its matching Action Log bullet.
add_green() {
  local idir="$1" issue="$2" fid="$3"
  printf '{"schema_version":1,"timestamp":"2026-07-18T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"generator-subagent","harness.lifecycle_step":"green_handback","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$issue" "$fid" >> "${idir}/trace.jsonl"
  printf -- '- [generator-subagent] green_handback %s pass — fixture green\n' \
    "$fid" >> "${idir}/progress.md"
}

# add_verdict <idir> <issue> <fid>: append one schema-shaped review_verdict/pass
# agent span (the per-feature verdict) plus its matching Action Log bullet, so
# review_verdict_missing is NOT emitted for <fid>.
add_verdict() {
  local idir="$1" issue="$2" fid="$3"
  printf '{"schema_version":1,"timestamp":"2026-07-18T12:05:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"pass"}\n' \
    "$issue" "$fid" >> "${idir}/trace.jsonl"
  printf -- '- [code-review-subagent] review_verdict %s pass — fixture verdict\n' \
    "$fid" >> "${idir}/progress.md"
}

# set_marker <dir>: record the current HEAD as review-approved at the main-root
# marker path (single repo, so main root == repo toplevel), so approval passes
# on the check path and the missing verdict is the only variable.
set_marker() {
  local dir="$1" marker
  marker="$(marker_path "$dir")"
  mkdir -p "${marker%/*}"
  git -C "$dir" rev-parse HEAD > "$marker"
}

marker_path() {
  local dir="$1" branch issue
  branch="$(git -C "$dir" branch --show-current)"
  issue="${branch#feature/issue-}"
  issue="${issue%%-*}"
  printf '%s' "${dir}/.copilot-tracking/review-gate/issue-${issue}/approved-head"
}

run_in() { # run_in <dir> <out> <env...> -- <cmd...>
  local dir="$1" out="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local rc=0
  (cd "$dir" && env PATH="$BIN" ${envs[@]+"${envs[@]}"} "$@") > "$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

OUT="${TMP_DIR}/out.txt"

# ============================================================================
# Case 1: approve_blocks_verdict_missing (issue 40)
# ============================================================================
C1="${TMP_DIR}/c40"; make_repo "$C1" 40
ID1="${C1}/.copilot-tracking/issues/issue-40"
add_green "$ID1" 40 feat-a
rc="$(run_in "$C1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "approve_blocks_verdict_missing: 'review-gate.sh approve' must HARD-FAIL when a passes:true feature lacks a review_verdict span, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$C1")" ] \
  || fail "approve_blocks_verdict_missing: the approved-head marker must NOT be written when a per-feature verdict is missing (marker present at $(marker_path "$C1"))"
grep -Eiq 'verdict' "$OUT" \
  || fail "approve_blocks_verdict_missing: the refusal must name the missing per-feature review verdict (output: $(tr '\n' '|' < "$OUT"))"
grep -Eq 'feat-a' "$OUT" \
  || fail "approve_blocks_verdict_missing: the refusal must name the feature (feat-a) whose verdict is missing (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2: check_blocks_verdict_missing (issue 41)
# ============================================================================
C2="${TMP_DIR}/c41"; make_repo "$C2" 41
ID2="${C2}/.copilot-tracking/issues/issue-41"
add_green "$ID2" 41 feat-a
set_marker "$C2"   # approval matches HEAD
rc="$(run_in "$C2" "$OUT" SKIP_CI_GATE=1 -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check_blocks_verdict_missing: 'review-gate.sh check' must HARD-FAIL on the missing verdict even when approval passes, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'verdict' "$OUT" \
  || fail "check_blocks_verdict_missing: the check refusal must name the missing per-feature review verdict (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 3: no_block_with_verdict (issue 42)
# ============================================================================
C3="${TMP_DIR}/c42"; make_repo "$C3" 42
ID3="${C3}/.copilot-tracking/issues/issue-42"
add_green "$ID3" 42 feat-a
add_verdict "$ID3" 42 feat-a
rc="$(run_in "$C3" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "no_block_with_verdict: with a review_verdict span present the verdict leg must NOT block approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C3")" ] \
  || fail "no_block_with_verdict: approve must write the approved-head marker when the per-feature verdict is present"
if [ -f "$(marker_path "$C3")" ]; then
  [ "$(head -n1 "$(marker_path "$C3")" | tr -d '[:space:]')" = "$(git -C "$C3" rev-parse HEAD)" ] \
    || fail "no_block_with_verdict: the approved-head marker must equal the current HEAD"
fi
if grep -Eiq 'review_verdict_missing|missing.{0,20}verdict|verdict.{0,20}missing' "$OUT"; then
  fail "no_block_with_verdict: the verdict-missing refusal message must be ABSENT when the verdict is present (output: $(tr '\n' '|' < "$OUT"))"
fi

# ============================================================================
# Case 4: graceful_skip_no_trace (issue 43)
# ============================================================================
# feat-a is passes:true but NO trace.jsonl is planted, so
# check-trace-consistency exits 2 (checker could not run). The verdict gate
# must degrade to a skip (return 0) rather than break the gate, so approve
# still proceeds and writes the marker.
C4="${TMP_DIR}/c43"; make_repo "$C4" 43
rc="$(run_in "$C4" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "graceful_skip_no_trace: with no trace the verdict gate must degrade to a skip (return 0), not break approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C4")" ] \
  || fail "graceful_skip_no_trace: approve must write the approved-head marker when the verdict gate skips gracefully"

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d verdict PR-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'verdict PR-gate contract honored\n'
)

(
cd "$ROOT"

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

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_TRACE_CONSISTENCY \
  REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE 2>/dev/null || true

command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (check-trace-consistency and this sensor are jq-driven)"
for s in review-gate.sh check-trace-consistency.sh \
         trace-lib.sh issue-lib.sh; do
  [ -x "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found or not executable — required by the reject-cap PR-gate fixture"
done

# --- Pinned PATH --------------------------------------------------------------
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    if [ -n "$p" ]; then
      ln -sf "$p" "${dir}/${t}"
    fi
  done
}
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut \
  grep printf jq date od wc awk sort comm uniq mktemp head tail ls cp mv ln touch \
  uname true false

# --- Fixture builder ----------------------------------------------------------
# make_repo <dir> <issue>: a single git repo carrying review-gate.sh + deps at
# scripts/, a `main` baseline, then a feature/issue-NN-* branch with a
# docs/PROGRESS.md change committed as inert historical fixture data. Plants a
# main-root issue dir with an empty Action Log progress.md
# and a feat-a passes:false feature list. Per-case setup appends spans/bullets.
make_repo() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  git clone -q "$REPO" "$dir"
  git -C "$dir" remote remove origin
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in review-gate.sh check-trace-consistency.sh \
           trace-lib.sh issue-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "${ROOT}/docs/evaluation/trace-schema.v1.json" "${dir}/docs/evaluation/"
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs scripts
  git -C "$dir" commit -q -m "add review fixture"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$issue" > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "issue-${issue}: progress update"
  local idir="${dir}/.copilot-tracking/issues/issue-${pad}"
  mkdir -p "$idir"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${idir}/progress.md"
  printf '{"issue":%s,"features":[{"id":"feat-a","title":"A","passes":false}]}\n' "$issue" \
    > "${idir}/feature_list.json"
}

# add_reject <idir> <issue> <fid>: append one schema-shaped review_verdict/fail
# agent span to the main-root trace AND its matching Action Log bullet, so the
# span/bullet multisets stay consistent and the reject cap is the only signal.
add_reject() {
  local idir="$1" issue="$2" fid="$3"
  printf '{"schema_version":1,"timestamp":"2026-07-18T12:00:00Z","span":"agent","harness.issue":%s,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"%s","harness.outcome":"fail"}\n' \
    "$issue" "$fid" >> "${idir}/trace.jsonl"
  printf -- '- [code-review-subagent] review_verdict %s fail — fixture rejection\n' \
    "$fid" >> "${idir}/progress.md"
}

# set_marker <dir>: record the current HEAD as review-approved at the main-root
# marker path (single repo, so main root == repo toplevel), so approval passes
# on the check path and the reject cap is the only variable.
set_marker() {
  local dir="$1" marker
  marker="$(marker_path "$dir")"
  mkdir -p "${marker%/*}"
  git -C "$dir" rev-parse HEAD > "$marker"
}

marker_path() {
  local dir="$1" branch issue
  branch="$(git -C "$dir" branch --show-current)"
  issue="${branch#feature/issue-}"
  issue="${issue%%-*}"
  printf '%s' "${dir}/.copilot-tracking/review-gate/issue-${issue}/approved-head"
}

run_in() { # run_in <dir> <out> <env...> -- <cmd...>
  local dir="$1" out="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local rc=0
  (cd "$dir" && env PATH="$BIN" ${envs[@]+"${envs[@]}"} "$@") > "$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

OUT="${TMP_DIR}/out.txt"

# ============================================================================
# Case 1: approve_blocks_reject_cap (issue 30)
# ============================================================================
C1="${TMP_DIR}/c30"; make_repo "$C1" 30
ID1="${C1}/.copilot-tracking/issues/issue-30"
add_reject "$ID1" 30 feat-a
add_reject "$ID1" 30 feat-a
add_reject "$ID1" 30 feat-a
rc="$(run_in "$C1" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" != "0" ] \
  || fail "approve_blocks_reject_cap: 'review-gate.sh approve' must HARD-FAIL when a feature hit the 3-rejection cap, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ ! -f "$(marker_path "$C1")" ] \
  || fail "approve_blocks_reject_cap: the approved-head marker must NOT be written when the reject cap is exceeded (marker present at $(marker_path "$C1"))"
grep -Eiq 'reject' "$OUT" \
  || fail "approve_blocks_reject_cap: the refusal must name the review-rejection cap (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'stop|hand[ -]?back|human' "$OUT" \
  || fail "approve_blocks_reject_cap: the refusal must state the issue STOPS and hands back to the human (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2: check_blocks_reject_cap (issue 31)
# ============================================================================
C2="${TMP_DIR}/c31"; make_repo "$C2" 31
ID2="${C2}/.copilot-tracking/issues/issue-31"
add_reject "$ID2" 31 feat-a
add_reject "$ID2" 31 feat-a
add_reject "$ID2" 31 feat-a
set_marker "$C2"   # approval matches HEAD
rc="$(run_in "$C2" "$OUT" SKIP_CI_GATE=1 -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "check_blocks_reject_cap: 'review-gate.sh check' must HARD-FAIL on the reject cap even when approval passes, got exit ${rc} (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'reject' "$OUT" \
  || fail "check_blocks_reject_cap: the check refusal must name the review-rejection cap (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# Case 2b: release_reject_cap (issue 33) — the human-release half of the stop
# rule (#383): RELEASE_REJECT_CAP=1 lets a capped issue proceed, logged and
# trace-recorded, never silently.
# ============================================================================
C2B="${TMP_DIR}/c33"; make_repo "$C2B" 33
ID2B="${C2B}/.copilot-tracking/issues/issue-33"
add_reject "$ID2B" 33 feat-a
add_reject "$ID2B" 33 feat-a
add_reject "$ID2B" 33 feat-a
rc="$(run_in "$C2B" "$OUT" RELEASE_REJECT_CAP=1 -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "release_reject_cap: RELEASE_REJECT_CAP=1 must release the capped approve path — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C2B")" ] \
  || fail "release_reject_cap: approve must write the approved-head marker under a released cap"
grep -Eiq 'release' "$OUT" \
  || fail "release_reject_cap: the release must be LOGGED, never silent (output: $(tr '\n' '|' < "$OUT"))"
grep -Eiq 'review_reject_cap_exceeded' "$OUT" \
  || fail "release_reject_cap: the release log must carry the cap findings it overrides (output: $(tr '\n' '|' < "$OUT"))"
grep -q 'review-gate.reject-cap-release' "${ID2B}/trace.jsonl" \
  || fail "release_reject_cap: the release must be recorded as a reject-cap-release span in the issue trace"
rc="$(run_in "$C2B" "$OUT" RELEASE_REJECT_CAP=1 REQUIRE_TRACE_CONSISTENCY=1 SKIP_CI_GATE=1 -- ./scripts/review-gate.sh check)"
[ "$rc" = "0" ] \
  || fail "release_reject_cap: the release must also cover the strict trace gate (REQUIRE_TRACE_CONSISTENCY=1) — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
rc="$(run_in "$C2B" "$OUT" REQUIRE_TRACE_CONSISTENCY=1 SKIP_CI_GATE=1 -- ./scripts/review-gate.sh check)"
[ "$rc" != "0" ] \
  || fail "release_reject_cap: without RELEASE_REJECT_CAP=1 the capped check path must still hard-block, got exit ${rc}"

# ============================================================================
# Case 3: no_block_below_cap (issue 32)
# ============================================================================
C3="${TMP_DIR}/c32"; make_repo "$C3" 32
ID3="${C3}/.copilot-tracking/issues/issue-32"
add_reject "$ID3" 32 feat-a
add_reject "$ID3" 32 feat-a
rc="$(run_in "$C3" "$OUT" -- ./scripts/review-gate.sh approve)"
[ "$rc" = "0" ] \
  || fail "no_block_below_cap: with only 2 rejections the reject-cap leg must NOT block approve — expected exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
[ -f "$(marker_path "$C3")" ] \
  || fail "no_block_below_cap: approve must write the approved-head marker when the reject cap is not exceeded"
if [ -f "$(marker_path "$C3")" ]; then
  [ "$(head -n1 "$(marker_path "$C3")" | tr -d '[:space:]')" = "$(git -C "$C3" rev-parse HEAD)" ] \
    || fail "no_block_below_cap: the approved-head marker must equal the current HEAD"
fi
if grep -Eiq 'reject.{0,20}cap|rejection cap' "$OUT"; then
  fail "no_block_below_cap: the reject-cap refusal message must be ABSENT below the cap (output: $(tr '\n' '|' < "$OUT"))"
fi

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d reject-cap PR-gate contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'reject-cap PR-gate contract honored\n'
)

(
cd "$ROOT"
TMP_DIR="$(mktemp -d)"
trap 'cd /; rm -rf "${TMP_DIR}"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FIX="${TMP_DIR}/repo"
git clone -q "$REPO" "$FIX"
git -C "$FIX" remote remove origin
mkdir -p "${FIX}/scripts" "${FIX}/docs" "${FIX}/.copilot/skills"
for f in review-gate.sh issue-lib.sh trace-lib.sh ci-coverage-lib.sh check-trace-consistency.sh check-feature-list.sh; do
  [ -f "${ROOT}/scripts/$f" ] && cp "${ROOT}/scripts/$f" "${FIX}/scripts/"
done
printf 'guide\n' > "${FIX}/docs/guide.md"
printf 'doctrine\n' > "${FIX}/.copilot/skills/doc.md"
printf 'agents\n' > "${FIX}/AGENTS.md"
git -C "$FIX" config user.name t; git -C "$FIX" config user.email t@example.invalid
git -C "$FIX" checkout -q -b feature/issue-77-fixture
git -C "$FIX" add -A && git -C "$FIX" commit -qm "add docs fixture"
cd "$FIX"
mkdir -p .copilot-tracking/review-gate

./scripts/review-gate.sh approve >/dev/null 2>&1 || fail "approve failed"

# 1. docs-only delta carries
printf 'more\n' >> docs/guide.md && git add docs/guide.md && git commit -qm "docs: more"
out="$(./scripts/review-gate.sh check 2>&1)" || fail "docs-only delta must carry the approval (got: $out)"
grep -q "carried" <<<"$out" || fail "carry notice missing (got: $out)"

# 2. script delta must fail
printf '# x\n' >> scripts/issue-lib.sh && git add scripts/issue-lib.sh && git commit -qm "chore: touch"
if ./scripts/review-gate.sh check >/dev/null 2>&1; then
  fail "script delta must invalidate the approval"
fi
git reset -q --hard HEAD~1

# 3. doctrine markdown must fail
./scripts/review-gate.sh approve >/dev/null 2>&1
printf 'x\n' >> .copilot/skills/doc.md && git add .copilot/skills/doc.md && git commit -qm "docs: doctrine"
if ./scripts/review-gate.sh check >/dev/null 2>&1; then
  fail ".copilot/** markdown must invalidate the approval (doctrine is behavior)"
fi
git reset -q --hard HEAD~1

# 4. AGENTS.md must fail
./scripts/review-gate.sh approve >/dev/null 2>&1
printf 'x\n' >> AGENTS.md && git add AGENTS.md && git commit -qm "docs: agents"
if ./scripts/review-gate.sh check >/dev/null 2>&1; then
  fail "AGENTS.md must invalidate the approval (doctrine is behavior)"
fi

printf 'PASS: docs-only carry honors the review-diet-2 contract\n'
)
