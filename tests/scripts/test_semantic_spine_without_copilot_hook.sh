#!/usr/bin/env bash
# Regression + e2e sensor for issue #335 feature
# `copilot-runtime-capture-removal`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELECTOR="${1:-}"
SCRATCH="${ROOT}/.copilot-test-semantic-spine.$$"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_capture_absent() {
  [ ! -e "${ROOT}/scripts/copilot-trace-hook.sh" ] \
    || fail "core Copilot runtime reconstruction hook must be deleted"
  [ ! -e "${ROOT}/docs/runtime-adapters/github-copilot.hooks.example.json" ] \
    || fail "Copilot hook template must be deleted"
  if find "${ROOT}/tests/scripts" -maxdepth 1 -type f \
      \( -name 'test_copilot_hook_*.sh' -o -name 'test_trace_report_hook_absence_warning.sh' \) \
      | grep -q .; then
    fail "capture-only Copilot hook sensors must be deleted"
  fi
  ! grep -Eq 'copilot-trace-hook|interval-attribution' "${ROOT}/docs/harness-contract.yml" \
    || fail "harness contract must not require retired Copilot capture"
  ! grep -q '^COPILOT_OTEL_FILE_EXPORTER_PATH=' "${ROOT}/.env.example" \
    || fail "retired local OTel hook sink must be removed"
}

case "$SELECTOR" in
  "")
    bash "$0" regression
    bash "$0" e2e
    ;;
  regression)
    assert_capture_absent
    for record in \
      'id: trace-start-issue' \
      'id: trace-check-feature-list' \
      'id: trace-review-gate' \
      'id: trace-create-pr' \
      'id: trace-merge-pr' \
      'id: trace-finish-issue' \
      'id: trace-review-gate-trace' \
      'id: review-approval' \
      'id: ci-green-precondition' \
      'id: closeout-worktree-cleanup'; do
      grep -qF "$record" "${ROOT}/docs/harness-contract.yml" \
        || fail "kept semantic-spine or closeout contract record missing: ${record}"
    done
    grep -q 'trace_span' "${ROOT}/scripts/log-handback.sh" \
      || fail "log-handback.sh must keep emitting handback spans"
    printf 'semantic spine capture-removal regression passed\n'
    ;;
  e2e)
    assert_capture_absent
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    mkdir -p "${SCRATCH}/repo/scripts" "${SCRATCH}/repo/docs/evaluation" "${SCRATCH}/bin"
    for tool in bash sh env git basename dirname mkdir rmdir rm cat sed tr cut grep \
      printf jq date od wc awk sort comm uniq head tail ls cp mv ln touch mktemp uname true false; do
      path="$(command -v "$tool" || true)"
      [ -z "$path" ] || ln -s "$path" "${SCRATCH}/bin/${tool}"
    done
    cat > "${SCRATCH}/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue view"|"pr view"|"pr list") exit 1 ;;
esac
exit 0
SH
    chmod +x "${SCRATCH}/bin/gh"

    for script in issue-lib.sh start-issue.sh check-feature-list.sh review-gate.sh \
      finish-issue.sh finish-lib.sh trace-lib.sh trace-report.sh \
      check-trace-consistency.sh log-handback.sh; do
      cp "${ROOT}/scripts/${script}" "${SCRATCH}/repo/scripts/"
    done
    cp "${ROOT}/docs/evaluation/trace-schema.v1.json" \
      "${SCRATCH}/repo/docs/evaluation/trace-schema.v1.json"
    cat > "${SCRATCH}/repo/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "${SCRATCH}/repo/scripts/init.sh"
    git -C "${SCRATCH}/repo" init -q -b main
    git -C "${SCRATCH}/repo" config user.name "Harness Test"
    git -C "${SCRATCH}/repo" config user.email "harness-test@example.invalid"
    printf '.copilot-tracking/\n' > "${SCRATCH}/repo/.gitignore"
    printf 'fixture\n' > "${SCRATCH}/repo/README.md"
    printf '# Progress\n\nfixture\n' > "${SCRATCH}/repo/docs/PROGRESS.md"
    git -C "${SCRATCH}/repo" add .
    git -C "${SCRATCH}/repo" commit -q -m initial

    (
      cd "${SCRATCH}/repo"
      PATH="${SCRATCH}/bin" SKIP_INIT=1 ./scripts/start-issue.sh 42 SLUG=spine
    ) >"${SCRATCH}/start.out" 2>&1 || {
      cat "${SCRATCH}/start.out" >&2
      fail "real lifecycle start failed"
    }
    worktree="${SCRATCH}/repo-worktrees/issue-42"
    trace="${SCRATCH}/repo/.copilot-tracking/issues/issue-42/trace.jsonl"
    (
      cd "$worktree"
      PATH="${SCRATCH}/bin" ./scripts/log-handback.sh \
        conductor feature_start semantic-spine pass "semantic spine remains live"
    ) >"${SCRATCH}/handback.out" 2>&1 || {
      cat "${SCRATCH}/handback.out" >&2
      fail "real handback emission failed"
    }
    (
      cd "$worktree"
      PATH="${SCRATCH}/bin" REQUIRE_TRACE_CONSISTENCY=1 \
        ./scripts/review-gate.sh trace
    ) >"${SCRATCH}/gate.out" 2>&1 || {
      cat "${SCRATCH}/gate.out" >&2
      fail "semantic-spine consistency/review gate failed"
    }
    grep -qF 'trace consistent with progress.md, feature list, and review-gate state' \
      "${SCRATCH}/gate.out" \
      || fail "strict trace gate did not execute the consistency checker"
    grep -qF 'trace gate: no findings' "${SCRATCH}/gate.out" \
      || fail "strict trace gate did not report its passing verdict"
    jq -e 'select(.span == "tool"
      and .["gen_ai.tool.name"] == "review-gate.trace"
      and .["harness.outcome"] == "pass"
      and .["harness.violation_count"] == 0)' \
      "$trace" >/dev/null || fail "review-gate.trace pass span missing"
    jq -e 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "worktree_create")' \
      "$trace" >/dev/null || fail "real lifecycle span missing"
    jq -e 'select(.span == "agent"
      and .["harness.lifecycle_step"] == "feature_start"
      and .["harness.feature_id"] == "semantic-spine")' \
      "$trace" >/dev/null || fail "real handback span missing"
    if jq -e 'select(.["gen_ai.tool.name"] == "copilot-trace-hook")' "$trace" >/dev/null; then
      fail "trace contains runtime-reconstructed Copilot capture"
    fi
    cp "${worktree}/.copilot-tracking/issues/issue-42/progress.md" \
      "${SCRATCH}/repo/.copilot-tracking/issues/issue-42/progress.md"
    cp "${worktree}/.copilot-tracking/issues/issue-42/feature_list.json" \
      "${SCRATCH}/repo/.copilot-tracking/issues/issue-42/feature_list.json"
    cp "$trace" "${SCRATCH}/valid-trace.jsonl"
    printf '{malformed\n' >> "$trace"
    if (
      cd "${SCRATCH}/repo"
      PATH="${SCRATCH}/bin" FORCE=1 ABANDONED=1 \
        REQUIRE_TRACE_CONSISTENCY=1 \
        COPILOT_CLI_STATE_ROOT="${SCRATCH}/native-empty" \
        ./scripts/finish-issue.sh 42 SLUG=spine
    ) >"${SCRATCH}/negative-gate.out" 2>&1; then
      fail "strict closeout accepted a malformed trace"
    fi
    grep -q '^VIOLATION ' "${SCRATCH}/negative-gate.out" \
      || fail "malformed-trace proof did not report a checker violation"
    grep -qF 'trace gate blocked the finish (REQUIRE_TRACE_CONSISTENCY=1)' \
      "${SCRATCH}/negative-gate.out" \
      || fail "malformed-trace proof did not block closeout"
    [ -e "$worktree" ] || fail "blocked malformed-trace closeout removed the worktree"
    cp "${SCRATCH}/valid-trace.jsonl" "$trace"
    (
      cd "${SCRATCH}/repo"
      PATH="${SCRATCH}/bin" FORCE=1 ABANDONED=1 \
        COPILOT_CLI_STATE_ROOT="${SCRATCH}/native-empty" \
        ./scripts/finish-issue.sh 42 SLUG=spine
    ) >"${SCRATCH}/finish.out" 2>&1 || {
      cat "${SCRATCH}/finish.out" >&2
      fail "real closeout gate failed"
    }
    [ ! -e "$worktree" ] || fail "closeout did not remove the issue worktree"
    jq -e 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "finish")' \
      "$trace" >/dev/null || fail "closeout finish span missing"
    printf 'semantic spine without Copilot hook e2e passed\n'
    ;;
  *)
    fail "usage: $0 regression|e2e"
    ;;
esac
