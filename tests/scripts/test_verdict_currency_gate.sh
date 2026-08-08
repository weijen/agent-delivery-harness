#!/usr/bin/env bash
# test_verdict_currency_gate.sh — regression sensor for issue #447: approve
# must refuse when the newest per-feature review verdict does not cover HEAD's
# product content (the Unilever issue-21 sequence: 14 approvals rode on 3
# verdicts stamped hours earlier — 11 PRs of unreviewed code).
#
# One long, sequentially-mutated fixture repo (test_review_gate.sh pattern):
#   S1 verdict-at-head        verdict reviewed_sha == HEAD => approve passes
#   S2 stale-verdict          product commit after the verdict => approve
#                             refused, marker untouched (issue-21 sequence)
#   S3 repair-at-head         appending a repair verdict at HEAD => passes
#   S4 bookkeeping-carry      .copilot-tracking-only commit => passes
#   S5 rebase-carry           content-preserving rebase onto advanced
#                             origin/main => passes
#   S6 legacy-no-sha          newest verdict without reviewed_sha => passes
#                             (legacy tolerance) with a warning
#   S7 unknown-sha            newest verdict naming an unknown commit =>
#                             refused fail-closed
#
# Exit: 0 all scenarios pass · 1 otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts review-gate.sh
TMP_DIR="$FIXTURE_TMP_DIR"
REPO="$FIXTURE_REPO"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

_sfail=0
fail() {
  printf '# %s\n' "$*" >&2
  _sfail=1
}
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

cd "$REPO"
export TRACE_ISSUE=1

# Origin with main so _content_patch_id has a merge-base anchor; feature branch
# so the run models the real approve context.
git clone -q --bare "$REPO" "${TMP_DIR}/origin.git"
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main
git checkout -q -b feature/issue-01-fixture

TRACK_DIR="${REPO}/.copilot-tracking/issues/issue-01"
MARKER="${REPO}/.copilot-tracking/review-gate/issue-01/approved-head"
mkdir -p "$TRACK_DIR"

write_feature_list() {
  cat > "${TRACK_DIR}/feature_list.json" <<'JSON'
{
  "issue": 1,
  "features": [
    { "id": "F1", "title": "fixture feature", "passes": true }
  ]
}
JSON
}

# write_verdict <reviewed_sha_or_empty> [review_mode] — rewrite the trace with
# a single newest verdict for F1. Empty sha writes a legacy span without the
# reviewed_sha attribute.
write_verdict() {
  local sha="${1:-}" mode="${2:-full}"
  if [ -n "$sha" ]; then
    printf '{"schema_version":1,"timestamp":"2026-08-08T00:00:00Z","span":"agent","harness.issue":1,"span_id":"a000000000000001","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"F1","harness.outcome":"pass","harness.review_mode":"%s","harness.repair_scope":"F1","harness.reviewed_sha":"%s"}\n' \
      "$mode" "$sha" > "${TRACK_DIR}/trace.jsonl"
  else
    printf '{"schema_version":1,"timestamp":"2026-08-08T00:00:00Z","span":"agent","harness.issue":1,"span_id":"a000000000000002","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"F1","harness.outcome":"pass"}\n' \
      > "${TRACK_DIR}/trace.jsonl"
  fi
}

append_verdict() {
  local sha="$1" mode="${2:-repair}"
  printf '{"schema_version":1,"timestamp":"2026-08-08T00:10:00Z","span":"agent","harness.issue":1,"span_id":"a000000000000003","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"conductor","harness.lifecycle_step":"review_verdict","harness.feature_id":"F1","harness.outcome":"pass","harness.review_mode":"%s","harness.repair_scope":"F1","harness.reviewed_sha":"%s"}\n' \
    "$mode" "$sha" >> "${TRACK_DIR}/trace.jsonl"
}

approve() {
  bash scripts/review-gate.sh approve >"${TMP_DIR}/approve.out" 2>&1
}

# --- S1 verdict-at-head -------------------------------------------------------
printf 'v1\n' > product.txt
git add product.txt
git commit -q -m "feat: product v1"
write_feature_list
write_verdict "$(git rev-parse HEAD)"

if ! approve; then
  fail "S1: approve with verdict at HEAD should pass"
  sed 's/^/# /' "${TMP_DIR}/approve.out" >&2
fi
[ -f "$MARKER" ] || fail "S1: approved-head marker missing"
emit "verdict at HEAD passes"

# --- S2 stale-verdict (the issue-21 sequence) ---------------------------------
marker_before="$(cat "$MARKER")"
printf 'v2\n' > product.txt
git add product.txt
git commit -q -m "feat: product v2 (unreviewed)"

if approve; then
  fail "S2: approve must refuse — product content changed since the verdict"
fi
grep -q 'verdict currency' "${TMP_DIR}/approve.out" \
  || fail "S2: refusal must name the verdict currency gate"
[ "$(cat "$MARKER")" = "$marker_before" ] \
  || fail "S2: refused approve must not touch the marker"
emit "stale verdict refused, marker untouched"

# --- S3 repair verdict at HEAD ------------------------------------------------
append_verdict "$(git rev-parse HEAD)" repair
if ! approve; then
  fail "S3: approve after a repair verdict at HEAD should pass"
  sed 's/^/# /' "${TMP_DIR}/approve.out" >&2
fi
emit "repair verdict at HEAD passes"

# --- S4 bookkeeping-only commit carries ---------------------------------------
printf 'progress note\n' >> "${TRACK_DIR}/progress.md"
git add -f "${TRACK_DIR}/progress.md"
git commit -q -m "chore: bookkeeping only"

if ! approve; then
  fail "S4: bookkeeping-only commit must carry the verdict"
  sed 's/^/# /' "${TMP_DIR}/approve.out" >&2
fi
emit "bookkeeping-only commit carries"

# --- S5 content-preserving rebase carries -------------------------------------
# Advance origin/main with an unrelated commit, then rebase the branch onto it.
git clone -q "${TMP_DIR}/origin.git" "${TMP_DIR}/origin-work"
git -C "${TMP_DIR}/origin-work" config user.name "Harness Test"
git -C "${TMP_DIR}/origin-work" config user.email "harness-test@example.invalid"
printf 'upstream\n' > "${TMP_DIR}/origin-work/upstream.txt"
git -C "${TMP_DIR}/origin-work" add upstream.txt
git -C "${TMP_DIR}/origin-work" commit -q -m "feat: upstream change"
git -C "${TMP_DIR}/origin-work" push -q origin main
git fetch -q origin main
git rebase -q origin/main

# The newest verdict still names the pre-rebase HEAD; the rebase preserved
# branch content, so the gate must carry.
if ! approve; then
  fail "S5: content-preserving rebase must carry the verdict"
  sed 's/^/# /' "${TMP_DIR}/approve.out" >&2
fi
emit "content-preserving rebase carries"

# --- S6 legacy verdict without reviewed_sha -----------------------------------
write_verdict ""
if ! approve; then
  fail "S6: legacy verdict without reviewed_sha must be tolerated"
  sed 's/^/# /' "${TMP_DIR}/approve.out" >&2
fi
grep -q 'legacy trace' "${TMP_DIR}/approve.out" \
  || fail "S6: legacy tolerance must warn"
emit "legacy verdict without reviewed_sha tolerated with warning"

# --- S7 unknown reviewed_sha refused ------------------------------------------
write_verdict "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
if approve; then
  fail "S7: unknown reviewed_sha must refuse fail-closed"
fi
grep -q 'unknown commit' "${TMP_DIR}/approve.out" \
  || fail "S7: refusal must name the unknown commit"
emit "unknown reviewed_sha refused"

tap_done
