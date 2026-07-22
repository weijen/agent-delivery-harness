#!/usr/bin/env bash
# create-pr.sh — sync onto latest main, push, and open the PR.
#
# Codifies the "sync with main before opening the PR" rule as an action instead
# of leaving it to the agent's judgement: a branch cut from a stale base can pass
# local gates yet break against current main (or duplicate a fix already landed).
#
# Usage:
#   ./scripts/create-pr.sh -h|--help          # print this usage and exit 0 —
#                                              # side-effect free: no git/gh call
#   ./scripts/create-pr.sh --title "feat: ..." --body-file body.md
#   ./scripts/create-pr.sh --title "fix: ..."  --body "..."
#   ./scripts/create-pr.sh                       # PR already exists: just re-sync + push
# Any extra args are passed straight through to `gh pr create`.
#
# Steps:
#   1. Refuse on main or a dirty tree.
#   2. Require review approval for the current HEAD before syncing.
#   3. git fetch origin main; rebase HEAD onto origin/main (abort cleanly on conflict) —
#      unless CREATE_PR_NO_REWRITE=1, which skips rebase entirely: open from the
#      current tip when origin/main is already an ancestor of HEAD, or merge
#      origin/main in (abort cleanly on conflict) when a sync is needed.
#   4. After a successful default rebase, attempt to carry the pre-rebase approval
#      forward by patch-id identity (issue #310): if the branch diff is unchanged
#      (same ordered patch stream), the prior approval is still valid and no second
#      approve is needed. Carry requires: exact pre-rebase HEAD match, a valid
#      non-blank stored identity, and an identical post-rebase identity. Any
#      content-changing commit/sync still needs fresh review — carry applies only
#      when the actual default rebase produced exactly the pre-approved HEAD, the
#      stored identity is a valid merge-free stable hex identity, and the
#      post-rebase identity is unchanged. After carry (or when carry is inapplicable),
#      the authoritative check always runs: merge/non-rewrite/fallback/legacy-marker
#      paths all require fresh approval. Carry is best-effort, not a guarantee.
#   5. Push the branch — --force-with-lease after a rebase (the issue branch is
#      yours alone), or a plain push after CREATE_PR_NO_REWRITE=1 (fast-forward-safe
#      by construction: a merge's first parent is the remote's own prior tip).
#      If --force-with-lease is rejected with a narrowly recognized force-push
#      policy signature (e.g. a "Block force pushes" rule) and NOT an auth,
#      network, or content-rejection signature, fall back reactively: restore
#      the LOCAL tip captured before this sync began (never the remote's own
#      ref — that would discard any not-yet-pushed local commit), merge
#      origin/main in, re-gate, and push without force. Force is never used
#      bare — only --force-with-lease.
#   6. Open the PR (gh pr create) if none exists yet, passing through your args.
#
# Push contract (issue #326 — force-with-lease is a single-writer-branch tool,
# never a main/shared-branch one, and rebase is a preference, not load-bearing):
#   - --force-with-lease applies only to the run's own single-writer feature
#     branch — the one this worktree owns exclusively — and never to main or
#     any shared branch (step 1's on-main refusal enforces this structurally).
#   - Rebase onto origin/main is the default preference for a linear history,
#     but it is not load-bearing: CREATE_PR_NO_REWRITE=1 skips it outright, and
#     a force-push-policy rejection triggers the same history-preserving
#     fallback automatically (step 5) — neither path is optional plumbing.
#   - Force is never used bare: only --force-with-lease, and a rejection that
#     is not a recognized force-push-policy signature (auth, network, or a
#     content-based rejection) is never swallowed as a fallback trigger.
#
# Exit codes: 0 PR open (or usage printed) · 1 precondition / conflict / PR creation failure

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

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
# cleanly (no leftover conflicted state, nothing pushed) on a conflict. Shared
# by the CREATE_PR_NO_REWRITE explicit path and the force-reject fallback path
# below: both need the identical "merge, or abort with the same recovery
# instructions" behavior (issue #326).
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

# _owned_ref_delete <ref> — best-effort delete of this script's own persistent
# pre-sync marker ref. Never fails the script: the ref may legitimately be
# absent (no rebase ran this sync cycle, or it was already cleaned up).
_owned_ref_delete() {
  git update-ref -d "$1" >/dev/null 2>&1 || true
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Help guard (issue #328) --------------------------------------------------
# -h/--help must exit 0 before ANY side effect (review-gate check, git fetch,
# git rebase, git push, gh call, or trace span emission) — scanned across all
# of $@, and placed before the trace-lib.sh guarded-source block below so no
# pr_create span is ever armed for a help request.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/create-pr.sh [--title TITLE] [--body BODY | --body-file FILE] [gh pr create args...]

Sync the current branch onto latest main, push it, and open (or re-sync) its
PR. Any argument other than -h/--help is passed straight through to
`gh pr create` (run `gh pr create --help` for its own flags). With no
PR-creation args and no existing PR, re-run with e.g.
--title "…" --body-file body.md.
EOF
      exit 0
      ;;
  esac
done

if [ -f "${SCRIPT_DIR}/github-identity-lib.sh" ]; then
  # shellcheck source=scripts/github-identity-lib.sh
  source "${SCRIPT_DIR}/github-identity-lib.sh"
  harness_identity_activate
fi

# --- Tracing (issue #94, plan D5) --------------------------------------------
# Guarded source: a missing trace-lib.sh must never break PR creation. The
# script runs inside the issue worktree, so trace-lib resolves the issue from
# the feature/issue-NN-* branch and pins the trace to the MAIN root (plan D1).
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi
if ! declare -F trace_span >/dev/null 2>&1; then
  TRACE_NOOP_WARNED=0
  trace_span() {
    if [ "${TRACE_NOOP_WARNED}" = "0" ]; then
      printf 'create-pr: warning: scripts/trace-lib.sh not found — trace spans disabled\n' >&2
      TRACE_NOOP_WARNED=1
    fi
    return 0
  }
  trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
  trace_lifecycle_init() { :; }
  trace_lifecycle_arm() { :; }
fi

# Exactly ONE pr_create lifecycle terminal span per invocation via the shared
# EXIT-trap helper (issue #213 P-1, trace_lifecycle_init). TRACE_STAGE names the
# last stage reached (preconditions|review_gate|rebase|fallback_sync|
# post_sync_gate|push|pr_create|done) and is surfaced as harness.stage by the
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
trace_lifecycle_arm
if [ -n "$(git status --porcelain)" ]; then
  red "✗ Working tree is dirty. Commit or stash before syncing onto main."
  git status --short
  exit 1
fi

# --- 1. Review approval gate ------------------------------------------------
TRACE_STAGE="review_gate"
"$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" check

# --- 2. Sync onto the latest main -------------------------------------------
# CREATE_PR_NO_REWRITE=1 is the explicit, proactive non-rewriting mode (issue
# #326): rebase stays the unconditional DEFAULT preference below; setting the
# flag skips it entirely instead of ever calling `git rebase`.
CREATE_PR_NO_REWRITE="${CREATE_PR_NO_REWRITE:-0}"
TRACE_STAGE="rebase"
sync_mode="rebase"
# did_rebase: tracks whether THIS invocation actually executed a successful
# default rebase (not inferred from sync_mode, since no-op ancestor cases
# deliberately retain sync_mode=rebase for push behavior). Only a successful
# git rebase call sets this to 1. Carry (issue #310) is attempted only when
# did_rebase=1 so it never fires on no-op, retry, CREATE_PR_NO_REWRITE merge,
# fallback merge, rebase conflict, or any other path.
did_rebase=0
# pre_rebase_head: captured immediately before the actual rebase runs. Used by
# the carry subcommand to verify the expected pre-rebase HEAD (issue #310).
pre_rebase_head=""
# owned_ref: this script's OWN branch-scoped, cross-invocation persistent
# marker for the true pre-rebase local tip — never git's own ORIG_HEAD.
# ORIG_HEAD is a single, repo-wide, unnamespaced pointer that ANY git command
# (reset, merge, pull, cherry-pick, another rebase run by hand, etc.) may
# overwrite between this run and the next; nothing validates that it still
# means "this script's pre-rebase tip" by the time a later invocation reads
# it. A namespaced ref this script alone writes and reads has no such
# ambiguity (issue #326).
owned_ref="refs/create-pr/presync/${branch}"
# _resolve_pre_sync_tip — the true pre-rebase local tip, resolved from
# owned_ref when a PRIOR invocation within this same sync cycle already
# rebased (owned_ref was written then, right before that rebase, and is never
# overwritten by the ancestor-satisfied "nothing to rebase this run" branch
# below), or from current HEAD when no script rebase has run this cycle at
# all (owned_ref is absent — the only case where "use current HEAD" is safe).
# If owned_ref DOES exist but fails to resolve to a real commit object
# (corrupted/pruned), that is a broken invariant, not an absent marker — fail
# loudly instead of silently falling back to HEAD, which could quietly
# restore the wrong tip. This is the ONLY safe restore point for the
# force-reject fallback further down: the local branch may legitimately carry
# commits that were never pushed (normal first PR-open/re-sync behavior), and
# the remote's own ref tip is necessarily behind those — resetting to the
# remote tip instead would permanently discard them.
_resolve_pre_sync_tip() {
  if git show-ref --verify --quiet "$owned_ref"; then
    if ! git rev-parse -q --verify "${owned_ref}^{commit}" >/dev/null 2>&1; then
      red "✗ ${owned_ref} exists but does not resolve to a valid commit — refusing to guess a restore point."
      echo "  This should not happen under normal operation. Inspect/remove the ref manually:"
      echo "    git update-ref -d ${owned_ref}"
      exit 1
    fi
    git rev-parse "$owned_ref"
  else
    git rev-parse HEAD
  fi
}
if [ "$CREATE_PR_NO_REWRITE" = "1" ]; then
  bold "==> CREATE_PR_NO_REWRITE=1 — skipping rebase (non-rewriting mode)"
  git fetch origin main
  if git merge-base --is-ancestor origin/main HEAD; then
    sync_mode="none"
    green "✓ ${branch} already contains latest origin/main ($(git rev-parse --short origin/main)) — opening from current tip"
  else
    _merge_main_or_die "CREATE_PR_NO_REWRITE=1 ./scripts/create-pr.sh"
    sync_mode="merge"
    green "✓ ${branch} merged latest origin/main ($(git rev-parse --short origin/main)) — no history rewritten"
  fi
else
  bold "==> Syncing ${branch} onto latest origin/main"
  git fetch origin main
  # Ancestor-check first (same as the CREATE_PR_NO_REWRITE branch above): a
  # `git rebase` call when origin/main is already an ancestor of HEAD is not
  # merely redundant — by default it DROPS any merge commit already on HEAD
  # (e.g. a fallback merge from a prior run, issue #326) and replays only the
  # non-merge commits, silently re-rewriting history a prior run deliberately
  # chose not to rewrite. Skipping the call when nothing needs rebasing keeps
  # that guarantee intact across repeated runs.
  if git merge-base --is-ancestor origin/main HEAD; then
    # HEAD already contains origin/main — nothing to rebase THIS run. This
    # may be because an EARLIER run already rebased this same sync cycle (in
    # which case owned_ref carries that true pre-rebase tip and must NOT be
    # overwritten here — HEAD's current, already-rebased value is no longer
    # the remote's own not-yet-pushed prior tip), or because no rebase has
    # run at all this cycle (owned_ref absent — HEAD is already correct, and
    # _resolve_pre_sync_tip falls back to it safely, since no prior script
    # rebase is involved either way when it's absent).
    pre_sync_tip="$(_resolve_pre_sync_tip)"
    green "✓ ${branch} already contains latest origin/main ($(git rev-parse --short origin/main)) — nothing to rebase"
  else
    # About to perform the actual rebase this run: capture HEAD *before* it
    # moves and persist it to owned_ref — this is the one and only place this
    # script ever writes owned_ref, immediately before the sole git command
    # that rewrites this branch's history. If update-ref fails, set -e must
    # stop before the rebase runs; once rebase starts, the restore ref is
    # already in place.
    pre_rebase_head="$(git rev-parse HEAD)"
    git update-ref "$owned_ref" "$pre_rebase_head"
    if git rebase origin/main; then
      pre_sync_tip="$pre_rebase_head"
      did_rebase=1
      green "✓ ${branch} is now on top of origin/main ($(git rev-parse --short origin/main))"
    else
      git rebase --abort || true
      # The attempt failed and HEAD never moved — clean up so a future cycle
      # never reads a stale marker from this aborted attempt.
      _owned_ref_delete "$owned_ref"
      red "✗ Rebase onto origin/main hit conflicts."
      echo "  Resolve them manually:"
      echo "    git rebase origin/main   # fix conflicts, git add, git rebase --continue"
      echo "  then re-run ./scripts/create-pr.sh"
      exit 1
    fi
  fi
fi

# --- 3. Review approval for the final HEAD ----------------------------------
# Only re-checked when HEAD actually moved: a no-op non-rewriting sync
# (sync_mode=none) never rewrites or advances HEAD, so the pre-sync approval
# above still covers it — re-checking would just repeat the same comparison.
TRACE_STAGE="post_sync_gate"
if [ "$sync_mode" != "none" ]; then
  # For a successful default rebase (did_rebase=1), attempt to carry the
  # pre-rebase approval forward by patch-id identity (issue #310). The carry
  # subcommand verifies marker line 1 matches the captured pre-rebase HEAD,
  # reads the stored patch-id, recomputes the current patch-id, and on an
  # exact match: updates the marker's line 1 to the post-rebase SHA and emits
  # a carry-annotated review_gate_approve span. Carry is best-effort only:
  # a nonzero exit (any mismatch or failure) leaves the marker unchanged;
  # the authoritative check runs immediately after regardless of carry outcome.
  # Never called on CREATE_PR_NO_REWRITE merge, fallback merge, no-op/retry,
  # or rebase conflict paths — did_rebase=1 is the sole trigger (issue #310).
  if [ "$did_rebase" = "1" ]; then
    _carry_rc=0
    "$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" carry-rebase-approval "$pre_rebase_head" \
      || _carry_rc=$?
    # Nonzero _carry_rc: carry inapplicable or impossible; diagnostic printed above.
    # Falls through to the authoritative check below.
  fi
  "$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" check
fi

# --- 4. Push -----------------------------------------------------------------
# --force-with-lease only after a rebase rewrote local history (the issue
# branch is single-owner); a non-rewriting sync (merge, or nothing to sync)
# pushes plain — fast-forward-safe by construction, since a merge's first
# parent is the remote's own prior tip.
#
# Reactive fallback (issue #326): if the remote rejects --force-with-lease
# with a narrowly recognized force-push-policy signature (e.g. a "Block force
# pushes" branch-protection rule) — and NOT an auth, network, or content-based
# signature — this is not treated as fatal. Instead: reset to pre_sync_tip —
# the LOCAL branch tip captured before step 2's sync ran, never the remote's
# ref — merge origin/main into that tip (a genuine, local-only,
# non-destructive merge — nothing already pushed is ever rewritten), require
# a fresh review approval for that new merge HEAD, and push it WITHOUT force
# (pre_sync_tip already descends from the remote's own prior tip, so the
# merge's first parent does too, making the push a plain fast-forward by
# construction). Restoring the remote's queried ref instead of pre_sync_tip
# would silently discard any clean local commit made after the branch's last
# push but before this sync (normal first PR-open/re-sync behavior) — exactly
# the defect this capture prevents. A rejection that does not carry that
# narrow signature is never swallowed — it fails exactly as loudly as it does
# today. Force is never issued bare anywhere in this script — only ever as
# --force-with-lease.
TRACE_STAGE="push"
bold "==> Pushing ${branch}"
if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  if [ "$sync_mode" = "rebase" ]; then
    if push_output="$(git push --force-with-lease origin "$branch" 2>&1)"; then
      printf '%s\n' "$push_output"
    elif _force_push_policy_blocked "$push_output"; then
      printf '%s\n' "$push_output" >&2
      yellow "⚠ force-with-lease rejected by remote policy — falling back to a non-rewriting sync"
      TRACE_STAGE="fallback_sync"
      # Never reset --hard on trust alone: resolve the remote's OWN current
      # branch tip and require it to be an ancestor of pre_sync_tip before
      # touching the working tree. If the remote tip cannot be resolved, or
      # is not an ancestor (someone/something else moved the remote branch
      # forward in a way pre_sync_tip does not already contain), resetting
      # to pre_sync_tip could silently discard remote history — fail loudly
      # instead, with nothing reset and nothing pushed (issue #326).
      remote_branch_tip="$(git ls-remote --exit-code origin "refs/heads/${branch}" 2>/dev/null | cut -f1)" || remote_branch_tip=""
      if [ -z "$remote_branch_tip" ]; then
        red "✗ Could not resolve the remote's current tip for ${branch} — refusing to reset."
        echo "  Check your GitHub auth/network and re-run once resolved:"
        echo "    ./scripts/create-pr.sh"
        exit 1
      fi
      if ! git merge-base --is-ancestor "$remote_branch_tip" "$pre_sync_tip"; then
        red "✗ Remote tip for ${branch} is not an ancestor of the pre-sync restore point — refusing to reset."
        echo "  This should not happen under normal operation (someone/something else advanced"
        echo "  the remote branch). Investigate the remote branch state before retrying:"
        echo "    ./scripts/create-pr.sh"
        exit 1
      fi
      git reset --hard "$pre_sync_tip"
      git fetch origin main
      _merge_main_or_die "./scripts/create-pr.sh"
      green "✓ ${branch} merged latest origin/main ($(git rev-parse --short origin/main)) — no history rewritten"
      TRACE_STAGE="post_sync_gate"
      "$(dirname "${BASH_SOURCE[0]}")/review-gate.sh" check
      TRACE_STAGE="push"
      bold "==> Pushing ${branch} (non-rewriting)"
      git push origin "$branch"
    else
      printf '%s\n' "$push_output" >&2
      red "✗ Push rejected and it does not look like a force-push policy block."
      echo "  This is a genuine failure (auth, network, permissions, or a content-based rejection) —"
      echo "  check your GitHub auth/network/permissions and re-run once resolved:"
      echo "    ./scripts/create-pr.sh"
      exit 1
    fi
  else
    git push origin "$branch"
  fi
else
  git push -u origin "$branch"
fi
green "✓ Pushed"
# The branch is now in sync with (and reflected on) the remote by whichever
# path got us here — force-with-lease, plain, fallback, or a brand-new
# branch's first push. owned_ref's job (surviving an approval-gate retry or a
# policy-rejection fallback across invocations) is done; clean it up so a
# future sync cycle never reads a stale marker (issue #326).
_owned_ref_delete "$owned_ref"

# --- 5. Open the PR (if one doesn't already exist) --------------------------
TRACE_STAGE="pr_create"
pr_number="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -n "$pr_number" ]; then
  green "✓ PR #${pr_number} already exists — re-synced and pushed."
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
