#!/usr/bin/env bash
# test_reviewer_end_of_issue_contract.sh — regression sensor for the
# reviewer-facing end-of-issue review contract (issue #303, feature
# reviewer-end-of-issue-contract).
#
# Contract under test (PINNED HERE as the executable spec): the reviewer docs
# must be consistent with the Loop 2 single-end-review model. The
# `code-review-subagent` agent contract
# (.copilot/agents/code-review-subagent.agent.md) must state, in its opening
# contract block, that it:
#   1. Reviews the COMPLETED issue diff / WHOLE branch diff ONCE, at issue
#      completion — NOT per feature mid-stream (per-feature verification is
#      owned by generator-subagent).
#   2. Issues PER-FEATURE verdicts (one per feature_list item).
#   3. Re-reviews a repaired feature in `repair` mode (per feature).
#   4. Preserves the read-only-on-production boundary (production assets are
#      read-only; the reviewer must not edit production).
#   5. Uses repository-bound identity activation / per-process tokens and never
#      mutates global GitHub CLI identity.
#
# It also pins the AGENTS.md doc-sync edit: the code-review-subagent portfolio
# row must no longer say review happens "after implementation completes" (which
# implies a per-feature round) and must name the issue-completion timing.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the reviewer contract still describes a per-feature mid-stream review round).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${ROOT}/.copilot/agents/code-review-subagent.agent.md"
AGENTS_MD="${ROOT}/AGENTS.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${AGENT}" ]; then
  printf 'FAIL: reviewer agent contract not found (%s)\n' "${AGENT}" >&2
  exit 1
fi

# Extract the opening contract block: from the "You are a CODE REVIEW SUBAGENT"
# line down to the "## What You Receive" heading. Anchoring the timing/verdict
# assertions here (rather than anywhere in the file) keeps them tied to the
# stated contract, so a lingering "whole branch diff" mention elsewhere (e.g. the
# pre-PR skill-battery paragraph) cannot mask a per-feature contract.
opening="$(sed -n '/^You are a CODE REVIEW SUBAGENT/,/^## What You Receive/p' "${AGENT}")"

if [ -z "${opening}" ]; then
  fail "could not locate the reviewer agent opening contract block"
fi

# Flatten the opening block to a single spaced line so multi-word phrase
# assertions are tolerant of markdown hard line-wraps (a phrase split across two
# physical lines still matches). This does not widen scope — the block boundary
# still anchors every assertion to the stated contract.
opening_flat="$(printf '%s' "${opening}" | tr '\n' ' ' | tr -s ' ')"

# 1. Reviews the completed issue diff / whole branch diff ONCE at issue completion.
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'at issue completion|once, at issue completion|once at issue completion' \
  || fail "opening contract must state the review runs once, at issue completion"
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'completed issue diff|whole branch diff' \
  || fail "opening contract must state it reviews the completed issue / whole branch diff"

# 1b. NOT invoked per feature mid-stream — per-feature verification owned by generator.
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'not invoked per feature|not .* per feature mid-stream' \
  || fail "opening contract must state it is NOT invoked per feature mid-stream"
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'per-feature verification .*(owned by|belongs to) .*(delivering agent|one agent)' \
  || fail "opening contract must state per-feature verification is owned by the delivering agent (#352)"

# 2. Issues per-feature verdicts.
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'per-feature verdict' \
  || fail "opening contract must state the single review issues per-feature verdicts"

# 3. Repaired feature re-reviewed in repair mode (per feature).
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'repair.{0,12}mode' \
  || fail "opening contract must state a repaired feature is re-reviewed in repair mode"
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'that feature only|per feature|for that feature' \
  || fail "opening contract must scope a NEEDS_REVISION route back to that feature"

# 4. Read-only-on-production boundary preserved (asserted anywhere in the file).
grep -qiE 'Production assets are read-only' "${AGENT}" \
  || fail "reviewer contract must preserve the 'Production assets are read-only' boundary"
grep -qiE 'must not edit production' "${AGENT}" \
  || fail "reviewer contract must preserve the 'must not edit production' boundary"

# 5. Repository-bound GitHub identity is part of the opening role contract.
printf '%s\n' "${opening_flat}" \
  | grep -qF 'harness_identity_activate' \
  || fail "opening contract must require harness_identity_activate"
printf '%s\n' "${opening_flat}" \
  | grep -qiE 'per-process (token|GitHub token)' \
  || fail "opening contract must require a per-process GitHub token"
printf '%s\n' "${opening_flat}" \
  | grep -qF 'gh auth switch' \
  || fail "opening contract must forbid gh auth switch"

# 6. AGENTS.md doc-sync: the code-review-subagent portfolio row must name the
# issue-completion timing and must NOT still say review fires "after
# implementation completes" (which implies a per-feature round).
if [ -f "${AGENTS_MD}" ]; then
  row="$(grep -E '^\| \*\*Subagent\*\* .code-review-subagent.' "${AGENTS_MD}" || true)"
  if [ -z "${row}" ]; then
    fail "AGENTS.md must keep a code-review-subagent portfolio row"
  else
    printf '%s\n' "${row}" \
      | grep -qiE 'issue completion' \
      || fail "AGENTS.md code-review-subagent row must state review runs at issue completion"
    if printf '%s\n' "${row}" | grep -qiE 'after implementation completes'; then
      fail "AGENTS.md code-review-subagent row must NOT say review fires 'after implementation completes'"
    fi
  fi
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d assertion(s) failed — reviewer end-of-issue contract not satisfied.\n' \
    "${fails}" >&2
  exit 1
fi

printf 'PASS: reviewer contract describes a single end-of-issue review with per-feature verdicts.\n'
