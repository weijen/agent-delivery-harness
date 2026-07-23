#!/usr/bin/env bash
# Regression sensor for feature_start gate retirement (#370).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

REPO="${TMP_DIR}/repo"
mkdir -p "${REPO}/scripts" "${REPO}/docs/evaluation"
for script in review-gate.sh check-trace-consistency.sh trace-lib.sh \
  issue-lib.sh; do
  cp "${ROOT}/scripts/${script}" "${REPO}/scripts/"
done
cp "${ROOT}/docs/evaluation/trace-schema.v1.json" \
  "${REPO}/docs/evaluation/"

git -C "${REPO}" init -q -b main
git -C "${REPO}" config user.name "Harness Test"
git -C "${REPO}" config user.email "harness-test@example.invalid"
git -C "${REPO}" config commit.gpgsign false
printf '.copilot-tracking/\n' >"${REPO}/.gitignore"
printf 'fixture\n' >"${REPO}/README.md"
git -C "${REPO}" add .gitignore README.md scripts docs
git -C "${REPO}" commit -q -m initial
git -C "${REPO}" checkout -q -b feature/issue-370-fixture
printf 'feature\n' >>"${REPO}/README.md"
git -C "${REPO}" add README.md
git -C "${REPO}" commit -q -m feature
git -C "${REPO}" remote add origin "${REPO}"
git -C "${REPO}" fetch -q origin main

ISSUE_DIR="${REPO}/.copilot-tracking/issues/issue-370"
mkdir -p "${ISSUE_DIR}"
printf '%s\n' \
  '{"issue":370,"features":[{"id":"feat-a","title":"A","passes":true,"verification":"green"}]}' \
  >"${ISSUE_DIR}/feature_list.json"
cat >"${ISSUE_DIR}/progress.md" <<'EOF'
# Issue 370 progress

## Action Log

- [conductor] green_handback feat-a pass - fixture green
- [code-review-subagent] review_verdict feat-a pass - fixture review
EOF
cat >"${ISSUE_DIR}/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-23T00:00:00Z","span":"agent","harness.issue":370,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"green_handback","harness.feature_id":"feat-a","harness.outcome":"pass"}
{"schema_version":1,"timestamp":"2026-07-23T00:00:01Z","span":"agent","harness.issue":370,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"feat-a","harness.outcome":"pass"}
EOF

CHECK_OUT="${TMP_DIR}/check.out"
(cd "${REPO}" && TRACE_ISSUE=370 ./scripts/check-trace-consistency.sh 370) \
  >"${CHECK_OUT}" 2>&1 || true
if grep -q 'feature_start_missing' "${CHECK_OUT}"; then
  cat "${CHECK_OUT}"
  fail "checker must not require feature_start for a passing feature"
fi

(cd "${REPO}" && TRACE_ISSUE=370 ./scripts/review-gate.sh approve) \
  >"${TMP_DIR}/approve.out" 2>&1 \
  || { cat "${TMP_DIR}/approve.out"; fail "approve must not require feature_start"; }
(cd "${REPO}" && TRACE_ISSUE=370 ./scripts/review-gate.sh check) \
  >"${TMP_DIR}/gate.out" 2>&1 \
  || { cat "${TMP_DIR}/gate.out"; fail "check must not require feature_start"; }

# Historical feature_start spans remain accepted by the trace schema.
cat >>"${ISSUE_DIR}/trace.jsonl" <<'EOF'
{"schema_version":1,"timestamp":"2026-07-23T00:00:02Z","span":"agent","harness.issue":370,"harness.version":"abc1234","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"feature_start","harness.feature_id":"feat-a","harness.outcome":"pass"}
EOF
(cd "${REPO}" && TRACE_ISSUE=370 ./scripts/check-trace-consistency.sh 370) \
  >"${TMP_DIR}/validate.out" 2>&1 \
  || { cat "${TMP_DIR}/validate.out"; fail "historical feature_start span must remain schema-valid"; }

printf 'PASS: feature_start is tolerated historically but no longer gates PR approval.\n'
