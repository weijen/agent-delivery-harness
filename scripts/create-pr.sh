#!/usr/bin/env bash
# create-pr.sh — prepare before validation, then publish the verified candidate.
#
# Usage:
#   ./scripts/create-pr.sh -h|--help          # print this usage and exit 0 —
#                                              # side-effect free: no git/gh call
#   ./scripts/create-pr.sh --prepare          # sync before final review/tests; no push
#   ./scripts/create-pr.sh --title "feat: ..." --body-file body.md
#   ./scripts/create-pr.sh --title "fix: ..."  --body "..."
#   ./scripts/create-pr.sh                       # existing PR: verify evidence + push
# Any extra args are passed straight through to `gh pr create`.
#
# --prepare fetches main and rebases, or merges with CREATE_PR_NO_REWRITE=1.
# It runs before final review/full pre-PR and never publishes or runs sensors.
# Normal invocation requires current-HEAD review and full pre-PR evidence,
# pushes that exact commit, and opens/updates the PR without synchronization.
# --force-with-lease is only for the exclusively owned issue branch, never main;
# CREATE_PR_NO_REWRITE=1 uses a plain push. Rejections never rewrite the candidate.
# Exit: 0 prepared/published/help · 1 refused/failed · 2 invalid preparation usage.

set -euo pipefail

# A push rejection "looks like" a remote force-push policy block (e.g. a
# GitHub branch-protection "Block force pushes" rule, or a modern GitHub
# Ruleset's protected-ref rule) only when it carries a known
# force-push/protected-ref signature AND does not also carry a signature for
# a genuinely different failure (auth, network, or a content-based rejection
# such as GitHub secret-scanning push protection). The deny-list is checked
# FIRST and wins on any overlap — ambiguous text is always treated as a
# genuine failure, never as a silent fallback trigger (issue #326).
#
# GH013 / "repository rule violations" is the umbrella error code GitHub
# Rulesets use for many unrelated rule kinds (protected-ref, required status
# checks, secret-scanning push protection, ...), so that text ALONE stays
# ambiguous — a hard failure — same as before. It is allow-listed ONLY when
# paired with the exact "Cannot update this protected ref." phrase AND no
# deny-list signature is present: that specific pairing is unambiguous
# evidence of a protected-ref/force-push policy block, not a content-based
# rejection (issue #326 security follow-up).
_force_push_policy_blocked() {
  local text="$1"
  if printf '%s' "$text" | grep -Eiq \
    'authentication failed|permission denied|could not read (username|password)|could not resolve host|connection (timed out|refused)|does not appear to be a git repository|could not read from remote repository|push protection|secret scanning|push cannot contain secrets'; then
    return 1
  fi
  if printf '%s' "$text" | grep -Eiq '(GH013|repository rule violations?)' \
    && printf '%s' "$text" | grep -Eiq 'cannot update this protected ref'; then
    return 0
  fi
  printf '%s' "$text" | grep -Eiq \
    'protected branch|cannot force-push|force push(es)? (is|are) not allowed|force-push.*(blocked|declined|disabled)|GH006'
}

# _merge_main_or_die — merge origin/main into the current HEAD, aborting
# cleanly (no leftover conflicted state, nothing pushed) on a conflict.
_merge_main_or_die() {
  local recovery_hint="$1"
  if ! git merge --no-edit origin/main; then
    git merge --abort || true
    red "✗ Merging origin/main hit conflicts."
    echo "  Resolve them manually:"
    echo "    git merge origin/main   # fix conflicts, git add, git commit"
    echo "  then re-run ${recovery_hint}"
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/lifecycle-runtime-lib.sh
source "${SCRIPT_DIR}/lib/lifecycle-runtime-lib.sh"

# --- Help guard (issue #328) --------------------------------------------------
# -h/--help must exit 0 before ANY side effect (review-gate check, git fetch,
# git rebase, git push, gh call, or trace span emission) — scanned across all
# of $@, and placed before tracing is initialized below so no
# pr_create span is ever armed for a help request.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/create-pr.sh [--title TITLE] [--body BODY | --body-file FILE] [gh pr create args...]
       ./scripts/create-pr.sh --prepare

Run --prepare before final review and full pre-PR validation. It synchronizes
the issue branch without requiring approval, running sensors or publishing.

Normal invocation checks current-HEAD review and full pre-PR evidence, then
pushes that candidate without synchronization or test execution. Arguments pass to
`gh pr create` (run `gh pr create --help` for its own flags). With no
PR-creation args and no existing PR, re-run with e.g.
--title "…" --body-file body.md.
EOF
      exit 0
      ;;
  esac
done

PREPARE_ONLY=0
if [ "${1:-}" = "--prepare" ]; then
  [ "$#" -eq 1 ] || { printf 'create-pr.sh: --prepare takes no other arguments\n' >&2; exit 2; }
  PREPARE_ONLY=1
  shift
fi

if [ -f "${SCRIPT_DIR}/lib/github-identity-lib.sh" ]; then
  # shellcheck source=scripts/lib/github-identity-lib.sh
  source "${SCRIPT_DIR}/lib/github-identity-lib.sh"
  harness_identity_activate "$(harness_identity_repo_root)"
fi

lifecycle_runtime_trace_init create-pr

# Exactly ONE pr_create lifecycle terminal span per invocation via the shared
# EXIT-trap helper (issue #213 P-1, trace_lifecycle_init). TRACE_STAGE names the
# last stage reached (preconditions|round_budget|review_gate|sensor_gate|
# push|pr_create|done) and is surfaced as harness.stage by the
# attr callback; the trap is armed only once past the on-main refusal, where a
# feature branch — and therefore a resolvable issue — exists, so that refusal
# emits nothing.
TRACE_STAGE=""
pr_number=""
trace__create_pr_attrs() {
  printf 'harness.stage=%s\n' "${TRACE_STAGE}"
  printf 'harness.branch=%s\n' "${branch:-}"
  [ -n "$pr_number" ] && printf 'harness.pr_number=%s\n' "${pr_number}"
}
trace_lifecycle_init pr_create trace__create_pr_attrs

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" = "main" ] || [ "$branch" = "HEAD" ]; then
  red "✗ Refusing to open a PR from '${branch}'. Switch to your feature branch first."
  exit 1
fi
TRACE_STAGE="preconditions"
if [ "$PREPARE_ONLY" -eq 0 ]; then trace_lifecycle_arm; fi
if [ -n "$(git status --porcelain)" ]; then
  red "✗ Working tree is dirty. Commit or stash before preparation or publication."
  git status --short
  exit 1
fi

# --- 0b. Post-PR termination guardrails (issue #450) --------------------------
# G3 green-freeze: the last merge attempt failed WITH green CI (branch
# protection, required approval, conflict). Every commit after green has only
# downside — refuse further rounds until a human acts.
# G1 round budget: post-PR progress cannot be proven (CI is non-monotonic —
# Unilever issue-20 went red→green→red), so rounds are BUDGETED. Unilever
# issue-21 burned 11 PR rounds over ~8 unsupervised hours; the cap converts
# that into one 30-second human direction check. A release is a human DESIGN
# RULING (#416 pattern), never a fourth automated repair.
TRACE_STAGE="round_budget"
guardrail_dir="$(guardrail_state_dir 2>/dev/null || true)"
if [ -n "$guardrail_dir" ] && [ -f "${guardrail_dir}/green-freeze" ]; then
  # A marker whose PR is no longer OPEN is stale — the human merged or closed
  # it out-of-band (the handback explicitly offers manual merge) — auto-clear
  # instead of freezing the NEXT PR of the issue on dead evidence
  # (reviewer F3). Unresolvable state (no gh, no pr= line) keeps the freeze:
  # fail-closed.
  frozen_pr="$(sed -n 's/^pr=//p' "${guardrail_dir}/green-freeze" 2>/dev/null | head -1)"
  frozen_pr_state=""
  if [ -n "$frozen_pr" ] && command -v gh >/dev/null 2>&1; then
    frozen_pr_state="$(gh pr view "$frozen_pr" --json state -q .state 2>/dev/null || true)"
  fi
  if [ -n "$frozen_pr_state" ] && [ "$frozen_pr_state" != "OPEN" ]; then
    yellow "⚠ green-freeze marker referenced PR #${frozen_pr} which is now ${frozen_pr_state} — stale, clearing."
    rm -f "${guardrail_dir}/green-freeze" "${guardrail_dir}/ci-red-history.tsv" 2>/dev/null || true
  elif [ "${RELEASE_GREEN_FREEZE:-0}" = "1" ]; then
    yellow "⚠ green-freeze released by RELEASE_GREEN_FREEZE=1 (human ruling, logged) — clearing the marker."
    rm -f "${guardrail_dir}/green-freeze"
    trace_span tool \
      "gen_ai.tool.name=create-pr.green-freeze-release" \
      "harness.outcome=pass"
  else
    red "✗ green-freeze active (#450 G3): the last merge attempt failed while CI was green."
    sed 's/^/  /' "${guardrail_dir}/green-freeze" 2>/dev/null || true
    echo "  The block is not fixable by more commits (protection/approval/conflict)."
    echo "  Hand back to a human; after the ruling, release with:"
    echo "    RELEASE_GREEN_FREEZE=1 ./scripts/create-pr.sh ..."
    exit 1
  fi
fi
round_cap="${POST_PR_ROUND_CAP:-3}"
if [ -n "$guardrail_dir" ] && [ -f "${guardrail_dir}/trace.jsonl" ] \
    && command -v jq >/dev/null 2>&1; then
  # Rounds are PER PR, not per issue: only pr_create pass spans AFTER the
  # most recent successful pr_merge count — a merge is the natural budget
  # reset, so a follow-up PR in the same issue starts fresh (reviewer F1).
  prior_rounds="$(jq -Rn \
    '[inputs | fromjson?] as $spans
     | ([$spans | to_entries[]
         | select((.value["harness.lifecycle_step"] // "") == "pr_merge")
         | select((.value["harness.outcome"] // "") == "pass")
         | .key] | max // -1) as $last_merge
     | [$spans | to_entries[]
        | select(.key > $last_merge)
        | .value
        | select((.["harness.lifecycle_step"] // "") == "pr_create")
        | select((.["harness.outcome"] // "") == "pass")] | length' \
    "${guardrail_dir}/trace.jsonl" 2>/dev/null || printf '0')"
  if [ "${prior_rounds:-0}" -ge "$round_cap" ]; then
    if [ "${RELEASE_POST_PR_ROUNDS:-0}" = "1" ]; then
      yellow "⚠ post-PR round budget: ${prior_rounds} prior rounds >= cap ${round_cap} — released by RELEASE_POST_PR_ROUNDS=1 (human ruling, logged)."
      trace_span tool \
        "gen_ai.tool.name=create-pr.round-cap-release" \
        "harness.outcome=pass" \
        "harness.round_count=${prior_rounds}" \
        "harness.round_cap=${round_cap}"
    else
      red "✗ post-PR round budget exceeded (#450 G1): ${prior_rounds} prior pr_create rounds for this issue (cap ${round_cap})."
      echo "  Post-PR progress cannot be proven; the budget is the termination guarantee."
      echo "  Prior rounds (from the trace):"
      jq -Rrn \
        '[inputs | fromjson?] as $spans
         | ([$spans | to_entries[]
             | select((.value["harness.lifecycle_step"] // "") == "pr_merge")
             | select((.value["harness.outcome"] // "") == "pass")
             | .key] | max // -1) as $last_merge
         | [$spans | to_entries[]
            | select(.key > $last_merge)
            | .value
            | select((.["harness.lifecycle_step"] // "") == "pr_create")
            | select((.["harness.outcome"] // "") == "pass")]
         | .[] | "    - \(.timestamp // "?")  commit \(.["harness.commit"] // "?")  PR #\(.["harness.pr_number"] // "?")"' \
        "${guardrail_dir}/trace.jsonl" 2>/dev/null || true
      echo "  Hand back to a human. If the human rules the direction sound, release with:"
      echo "    RELEASE_POST_PR_ROUNDS=1 ./scripts/create-pr.sh ..."
      exit 1
    fi
  fi
fi

# --- 1. Review approval gate ------------------------------------------------
TRACE_STAGE="review_gate"
if [ "$PREPARE_ONLY" -eq 0 ]; then
  verified_head="$(git rev-parse HEAD)"
  TRACE_COLLAPSE_CHILD_SPANS=1 \
    "$(dirname "${BASH_SOURCE[0]}")/validation/review-gate.sh" check
fi

# --- 2. Synchronize only during explicit preparation ------------------------
if [ "$PREPARE_ONLY" -eq 1 ]; then
  bold "==> Syncing ${branch} onto latest origin/main"
  git fetch origin main
  # Avoid dropping existing merge commits when main is already contained.
  if git merge-base --is-ancestor origin/main HEAD; then
    green "✓ ${branch} already contains latest origin/main ($(git rev-parse --short origin/main)) — nothing to rebase"
  elif [ "${CREATE_PR_NO_REWRITE:-0}" = "1" ]; then
    _merge_main_or_die "CREATE_PR_NO_REWRITE=1 ./scripts/create-pr.sh --prepare"
    green "✓ ${branch} merged latest origin/main — no history rewritten"
  elif git rebase origin/main; then
    green "✓ ${branch} is now on top of origin/main"
  else
    git rebase --abort || true
    red "✗ Rebase onto origin/main hit conflicts; preparation aborted."
    echo "  Resolve the conflict, then repeat preparation, review and full pre-PR."
    exit 1
  fi

  trace_span tool "gen_ai.tool.name=create-pr.prepare" "harness.outcome=pass"
  green "✓ Prepared $(git rev-parse HEAD). Complete review and the full pre-PR gate before publishing."
  exit 0
fi

# --- 3. Verify the exact candidate's full pre-PR evidence --------------------
TRACE_STAGE="sensor_gate"
if ! issue="$(trace__resolve_issue)"; then
  red "✗ Cannot resolve the issue for pre-PR evidence. Use an issue branch or TRACE_ISSUE."
  exit 1
fi
if ! "${SCRIPT_DIR}/validation/verify-sensor-evidence.sh" "$issue" \
  --head "$verified_head" --mode pre-pr; then
  red "✗ Full pre-PR evidence is missing or invalid for this candidate — refusing to push."
  echo "  Run ./scripts/run-sensors.sh --gate pre-pr after preparation and review."
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$verified_head" ] || [ -n "$(git status --porcelain)" ]; then
  red "✗ Candidate changed during verification — refusing to push."
  exit 1
fi

# --- 4. Push -----------------------------------------------------------------
# Pin the source refspec to the verified commit, not a mutable branch name.
TRACE_STAGE="push"
bold "==> Pushing ${branch}"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  if [ "${CREATE_PR_NO_REWRITE:-0}" != "1" ]; then
    if push_output="$(git push --force-with-lease origin "${verified_head}:refs/heads/${branch}" 2>&1)"; then
      printf '%s\n' "$push_output"
    elif _force_push_policy_blocked "$push_output"; then
      printf '%s\n' "$push_output" >&2
      red "✗ Remote policy rejected force-with-lease; the verified candidate was not rewritten."
      echo "  If this is a fast-forward, retry publication with CREATE_PR_NO_REWRITE=1."
      echo "  Otherwise prepare a history-preserving candidate explicitly, then repeat review and pre-PR."
      exit 1
    else
      printf '%s\n' "$push_output" >&2
      red "✗ Push rejected and it does not look like a force-push policy block."
      echo "  This is a genuine failure (auth, network, permissions, or a content-based rejection) —"
      echo "  check your GitHub auth/network/permissions and re-run once resolved:"
      echo "    ./scripts/create-pr.sh"
      exit 1
    fi
  else
    git push origin "${verified_head}:refs/heads/${branch}"
  fi
else
  git push origin "${verified_head}:refs/heads/${branch}"
  git branch --set-upstream-to="origin/${branch}" "$branch"
fi
green "✓ Pushed"

# --- 5. Open the PR (if one doesn't already exist) --------------------------
TRACE_STAGE="pr_create"
pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -n "$pr_number" ]; then
  green "✓ PR #${pr_number} already exists — verified candidate pushed."
else
  bold "==> Opening PR"
  if [ "$#" -eq 0 ]; then
    red "✗ No PR exists yet and no gh pr create args were given."
    echo "  Re-run with: ./scripts/create-pr.sh --title \"…\" --body-file body.md"
    exit 1
  fi
  gh pr create "$@" || {
    red "✗ gh pr create failed — the PR was not opened."
    echo "  Check your GitHub auth/network and re-run once resolved:"
    echo "    ./scripts/create-pr.sh --title \"…\" --body-file body.md"
    exit 1
  }
  pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
fi

if [ -z "$pr_number" ]; then
  red "✗ PR opened but its number could not be resolved."
  echo "  Check GitHub manually to confirm the PR state: gh pr view --web"
  exit 1
fi

TRACE_STAGE="done"
green "✓ PR #${pr_number} is open."
