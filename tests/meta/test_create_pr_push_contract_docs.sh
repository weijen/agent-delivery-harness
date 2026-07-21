#!/usr/bin/env bash
# test_create_pr_push_contract_docs.sh — regression sensor for issue #326
# feature create-pr-push-contract-docs.
#
# Cross-file consistency check: docs/HARNESS.md and scripts/create-pr.sh's own
# header comment must both explicitly state the create-pr push contract, so an
# operator guardrail prompt (e.g. "never force-push") has a correct, citable
# reference and cannot collide with this script's actual behavior the way the
# #317 incident did. Concretely, both artifacts must state:
#   - --force-with-lease applies only to the run's own single-writer feature
#     branch, and never to main or any shared branch;
#   - rebase onto origin/main is a preference, not load-bearing: it can be
#     skipped via CREATE_PR_NO_REWRITE=1, and a force-push-policy rejection
#     triggers the same history-preserving fallback reactively;
#   - the script never issues a bare --force push (only --force-with-lease).
# This is a static docs/comment consistency sensor — no runtime boundary, so
# there is no e2e_sensor for this feature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

DOC="docs/HARNESS.md"
SCRIPT="scripts/create-pr.sh"
[ -f "$DOC" ] || { echo "✗ missing $DOC"; exit 1; }
[ -f "$SCRIPT" ] || { echo "✗ missing $SCRIPT"; exit 1; }

# The script's header comment is the leading #-comment block before the first
# `set -euo pipefail` line — extract it so the assertions below check the
# documented contract, not incidental mentions deeper in the implementation.
header="$(awk '/^set -euo pipefail/{exit} {print}' "$SCRIPT")"

# --- docs/HARNESS.md: single-writer-branch-only force-with-lease -------------
grep -Eiq 'force-with-lease' "$DOC" \
  || note "$DOC must mention force-with-lease"
grep -Eiq 'single-writer' "$DOC" \
  || note "$DOC must state the single-writer-feature-branch scope of force-with-lease"
grep -Eiq 'never (to )?`?(main|shared branch)' "$DOC" \
  || note "$DOC must explicitly state force-with-lease is never used on main or a shared branch"

# --- docs/HARNESS.md: rebase preference, not load-bearing ---------------------
grep -q 'CREATE_PR_NO_REWRITE' "$DOC" \
  || note "$DOC must name the actual CREATE_PR_NO_REWRITE flag the code implements"
grep -Eiq 'not load-bearing' "$DOC" \
  || note "$DOC must state rebase is a preference that is not load-bearing"
grep -Eiq 'fallback automatically|history-preserving fallback' "$DOC" \
  || note "$DOC must describe the reactive history-preserving fallback"

# --- docs/HARNESS.md: never a bare --force ------------------------------------
grep -Eiq 'never.*bare.*force' "$DOC" \
  || note "$DOC must state the script never issues a bare --force push"

# --- scripts/create-pr.sh header: the same signatures, in the docs surface ---
printf '%s\n' "$header" | grep -Eiq 'force-with-lease' \
  || note "$SCRIPT header must mention force-with-lease"
printf '%s\n' "$header" | grep -Eiq 'single-writer' \
  || note "$SCRIPT header must state the single-writer-feature-branch scope of force-with-lease"
printf '%s\n' "$header" | grep -Eiq 'never (to )?`?(main|shared branch)' \
  || note "$SCRIPT header must explicitly state force-with-lease is never used on main or a shared branch"
printf '%s\n' "$header" | grep -q 'CREATE_PR_NO_REWRITE' \
  || note "$SCRIPT header must name CREATE_PR_NO_REWRITE"
printf '%s\n' "$header" | grep -Eiq 'not load-bearing' \
  || note "$SCRIPT header must state rebase is a preference that is not load-bearing"
printf '%s\n' "$header" | grep -Eiq 'fallback automatically|history-preserving fallback' \
  || note "$SCRIPT header must describe the reactive history-preserving fallback"
printf '%s\n' "$header" | grep -Eiq 'never.*bare.*force' \
  || note "$SCRIPT header must state force is never used bare (only --force-with-lease)"

# --- Both artifacts agree with reality: no bare --force anywhere in the script
# Reuses the exact static invariant from
# tests/scripts/test_create_pr_force_reject_fallback.sh scenario (c): every
# occurrence of --force in the implementation is immediately --force-with-lease.
if grep -Eq -- '(^|[^-])--force([^-]|$)' "$SCRIPT"; then
  note "$SCRIPT must never contain a bare --force token (only --force-with-lease is allowed) — docs would be lying about the implementation"
fi

if [ "$fail" -ne 0 ]; then
  echo "create-pr push-contract docs sensor FAILED"
  exit 1
fi
echo "create-pr push-contract docs sensor passed"
