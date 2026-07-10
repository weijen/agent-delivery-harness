#!/usr/bin/env bash
# test_log_completeness_trace.sh — RED sensor for the log-completeness gate trace/docs contract.
#
# Feature f4: log-completeness-docs-trace. The implementation must make
# `review-gate.sh log-completeness` emit exactly one tool span per resolved
# issue run, register harness.finding_count as a numeric trace key, and document
# the gate and REQUIRE_LOG_COMPLETE promotion flag.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT_YML="${ROOT}/docs/harness-contract.yml"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_PARENT="${ROOT}/.copilot-tracking/tmp-tests"
mkdir -p "${TMP_PARENT}"
TMP_DIR="$(TMPDIR="${TMP_PARENT}" mktemp -d)"
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
  REQUIRE_TRACE_CONSISTENCY REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the gate and this sensor are jq-driven)"
[ -f "$SCHEMA" ] || hard_fail "trace schema contract not found (${SCHEMA})"
[ -f "$CONTRACT_YML" ] || hard_fail "harness contract not found (${CONTRACT_YML})"
for s in review-gate.sh finish-issue.sh finish-lib.sh validate-trace.sh check-trace-consistency.sh \
         trace-lib.sh issue-lib.sh start-issue.sh check-feature-list.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || hard_fail "scripts/${s} not found — required by the log-completeness fixture"
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
cat > "${BIN}/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
chmod +x "${BIN}/gh"

# --- Fixture builder --------------------------------------------------------------
# make_gate_fixture <dir> <issue>: MAIN repo (all lifecycle scripts + schema
# contract at canonical paths) + worktree created by the REAL start-issue.sh,
# then the consistency artifact set planted at the MAIN root issue dir.
make_gate_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts" "${dir}/docs/evaluation"
  local s
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh \
           review-gate.sh trace-lib.sh validate-trace.sh check-trace-consistency.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  cp "$SCHEMA" "${dir}/docs/evaluation/trace-schema.v1.json"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add .gitignore README.md docs scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out" >&2; hard_fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || hard_fail "setup: worktree for issue ${issue} was not created"
  [ -f "${dir}/.copilot-tracking/issues/issue-${pad}/trace.jsonl" ] \
    || hard_fail "setup: start-issue emitted no main-root trace for issue ${issue}"
  mkdir -p "${dir}/.copilot-tracking/issues/issue-${pad}"
  printf '# Issue %s progress\n\nStatus: in progress.\n\n## Action Log\n\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/progress.md"
  printf '{"issue":%s,"features":[{"id":"feat-a","title":"A","steps":[],"passes":false}]}\n' "$issue" \
    > "${dir}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

last_logcomp_span() {
  jq -nRr '[inputs | fromjson?
            | select(.span == "tool" and .["gen_ai.tool.name"] == "review-gate.log-completeness")]
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
# CASE A/B/D: fixture issue 80, dirty progress placeholders
# ============================================================================
F1="${TMP_DIR}/f80"
make_gate_fixture "$F1" 80
WT1="${F1}-worktrees/issue-80"
TRACE1="${F1}/.copilot-tracking/issues/issue-80/trace.jsonl"
# The gate scans repo_root (the worktree toplevel via git rev-parse
# --show-toplevel) — exactly where log-handback.sh writes the live Action Log —
# so plant the placeholders in the WORKTREE progress.md, not the main root.
PROGRESS1="${WT1}/.copilot-tracking/issues/issue-80/progress.md"
mkdir -p "$(dirname "$PROGRESS1")"
cat > "$PROGRESS1" <<'MD'
# Issue 80 progress

## Action Log

- TBD: document the release evidence.
- TODO(fill me): capture review handback.
MD

# CASE A: warn-only emits a pass span with numeric finding_count=2.
rc="$(run_in "$WT1" "$OUT" -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "0" ] \
  || fail "CASE A: warn-only log-completeness must exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE1")"
[ -n "$span" ] \
  || fail "CASE A: no review-gate.log-completeness tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "pass")
      and ((.["harness.finding_count"] | type) == "number")
      and (.["harness.finding_count"] == 2)' >/dev/null 2>&1 \
    || fail "CASE A: span must carry harness.outcome=pass and NUMERIC harness.finding_count=2: ${span}"
fi

# CASE B: REQUIRE_LOG_COMPLETE blocks and emits fail span with numeric exit/finding counts.
rc="$(run_in "$WT1" "$OUT" REQUIRE_LOG_COMPLETE=1 -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "1" ] \
  || fail "CASE B: REQUIRE_LOG_COMPLETE=1 must exit 1 with placeholders, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE1")"
[ -n "$span" ] \
  || fail "CASE B: no review-gate.log-completeness tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      (.["harness.outcome"] == "fail")
      and ((.["harness.exit_status"] | type) == "number")
      and (.["harness.exit_status"] == 1)
      and ((.["harness.finding_count"] | type) == "number")
      and (.["harness.finding_count"] == 2)' >/dev/null 2>&1 \
    || fail "CASE B: span must carry harness.outcome=fail, NUMERIC harness.exit_status=1, and NUMERIC harness.finding_count=2: ${span}"
fi

# CASE D: validate-trace accepts the log-completeness span's numeric finding_count.
rc=0
(cd "$WT1" && env PATH="$BIN" ./scripts/validate-trace.sh 80) > "$OUT" 2>&1 || rc=$?
[ "$rc" = "0" ] \
  || fail "CASE D: validate-trace.sh must accept harness.finding_count as a registered numeric key, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"

# ============================================================================
# CASE C: clean fixture issue 81 emits numeric finding_count=0.
# ============================================================================
F2="${TMP_DIR}/f81"
make_gate_fixture "$F2" 81
WT2="${F2}-worktrees/issue-81"
TRACE2="${F2}/.copilot-tracking/issues/issue-81/trace.jsonl"
# Clean Action Log in the worktree (no placeholder signatures) — the gate must
# still emit a span carrying a numeric finding_count of 0.
PROGRESS2="${WT2}/.copilot-tracking/issues/issue-81/progress.md"
mkdir -p "$(dirname "$PROGRESS2")"
cat > "$PROGRESS2" <<'MD'
# Issue 81 progress

## Action Log

- feature_start demo pass — nothing outstanding.
MD
rc="$(run_in "$WT2" "$OUT" -- ./scripts/review-gate.sh log-completeness)"
[ "$rc" = "0" ] \
  || fail "CASE C: clean log-completeness must exit 0, got ${rc} (output: $(tr '\n' '|' < "$OUT"))"
span="$(last_logcomp_span "$TRACE2")"
[ -n "$span" ] \
  || fail "CASE C: no review-gate.log-completeness tool span emitted"
if [ -n "$span" ]; then
  printf '%s\n' "$span" | jq -e '
      ((.["harness.finding_count"] | type) == "number")
      and (.["harness.finding_count"] == 0)' >/dev/null 2>&1 \
    || fail "CASE C: clean span must emit NUMERIC harness.finding_count=0 (not omit it): ${span}"
fi

# CASE E: schema single-source declares harness.finding_count numeric.
jq -e '.numeric_keys | index("harness.finding_count") != null' "$SCHEMA" >/dev/null 2>&1 \
  || fail "CASE E: docs/evaluation/trace-schema.v1.json numeric_keys must include harness.finding_count"

# CASE F: HARNESS.md documents the gate and promotion flag.
grep -q 'log-completeness' "${ROOT}/docs/HARNESS.md" \
  || fail "CASE F: docs/HARNESS.md must mention log-completeness"
grep -q 'REQUIRE_LOG_COMPLETE' "${ROOT}/docs/HARNESS.md" \
  || fail "CASE F: docs/HARNESS.md must mention REQUIRE_LOG_COMPLETE"

if [ "$fails" -ne 0 ]; then
  printf 'test_log_completeness_trace: %s failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'test_log_completeness_trace: ok\n'
