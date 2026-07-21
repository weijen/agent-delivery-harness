#!/usr/bin/env bash
# test_create_pr_force_reject_fallback.sh — regression sensor for issue #326
# feature create-pr-force-reject-fallback.
#
# Contract under test:
#   In the DEFAULT (rebase) sync path, `git push --force-with-lease` can be
#   rejected by a genuine remote force-push policy (a "Block force pushes" /
#   protected-branch rule). That rejection must trigger a reactive, narrowly
#   scoped fallback — never a bare `--force`, and never a silent swallow of an
#   unrelated failure:
#
#   (a) Policy-blocked rejection triggers the fallback, AND preserves any
#       clean local commit made after the branch's last push but before this
#       run (normal first PR-open/re-sync behavior) — the fallback must
#       restore the pre-sync LOCAL tip, never the remote tip, or it silently
#       discards that commit. A real local bare `origin` with a `pre-receive`
#       hook that authentically rejects any non-fast-forward update to the
#       branch ref (the exact shape of a "Block force pushes" GitHub
#       branch-protection rule) rejects a `--force-with-lease` attempt.
#       Before that, a distinct local-only commit is made on top of the
#       already-pushed branch tip and never itself pushed. Reaching the
#       rejected push attempt first requires the ordinary (existing,
#       unchanged) "a rebase that changes HEAD needs a fresh approval before
#       it can be pushed" cycle: approve the pre-rebase tip (which already
#       includes the local-only commit), run once (rebase changes HEAD, the
#       post-sync gate refuses the unapproved result, nothing is pushed —
#       this is pre-existing behavior, not new in this feature), approve the
#       rebased HEAD, run again. On THIS run the rebase is a no-op (already
#       synced), the gate passes, and the push is attempted for real — where
#       the hook rejects it. The script does not treat that rejection as
#       fatal: it restores the pre-sync LOCAL tip captured before the rebase
#       (which still carries the local-only commit), merges `origin/main` in
#       (a local-only, non-destructive operation — nothing already pushed is
#       ever rewritten), and re-gates the new merge HEAD. Since that new HEAD
#       was never approved, the run still exits non-zero with the existing
#       "has not been approved" message and pushes nothing — but the
#       local-only commit's file must already be present in the working
#       tree at this point. After approving the merge HEAD, one more run
#       succeeds: HEAD ends as a merge commit (two parents — the remote's
#       pre-fallback tip and origin/main's tip), the PR opens, the
#       non-rewriting proof — the bare origin's OWN before/after ref values
#       for the branch have a strict ancestor relationship (the remote
#       history was only ever extended, never overwritten) — and the
#       local-only commit's file, with its original content, is present in
#       the pushed branch's own tree on the bare origin.
#   (b) A non-policy rejection (auth/network/generic) is never swallowed as a
#       fallback trigger: it stays exactly as loud a failure as it is today —
#       exit 1, the raw git failure text is what's printed, no merge is
#       attempted (HEAD stays the plain rebased commit), and no PR opens.
#   (c) Static invariant: scripts/create-pr.sh never issues a bare `--force`
#       push — every occurrence of `--force` is immediately `--force-with-lease`.
#
# Fixture style mirrors test_create_pr_no_rewrite.sh / test_create_pr_failure.sh:
# real git, a real local bare `origin` (with a real `pre-receive` hook for
# scenario (a)), and a fake `gh` on PATH.
#
# Exit codes: 0 all three assertions behave as contracted · 1 a regression.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# owned_ref_path <branch> — this script's own branch-scoped pre-sync marker
# ref name, mirrored from create-pr.sh's own `owned_ref="refs/create-pr/presync/${branch}"`.
owned_ref_path() {
  printf 'refs/create-pr/presync/%s' "$1"
}

# corrupt_orig_head <dir> — deliberately clobber git's own ORIG_HEAD with a
# well-formed-looking but bogus value between two create-pr.sh invocations
# within the same sync cycle. ORIG_HEAD is a single, repo-wide, unnamespaced
# pointer that ANY git command may legitimately overwrite; the fix under test
# must restore the true pre-rebase tip from its OWN owned_ref marker instead
# of ORIG_HEAD, so corrupting ORIG_HEAD here must have zero effect on the
# fallback's ability to recover the local-only commit (issue #326).
corrupt_orig_head() {
  local dir="$1"
  printf '0000000000000000000000000000000000000000\n' > "${dir}/.git/ORIG_HEAD"
}

# --- (c) Static invariant: never a bare force push ---------------------------
# Every `--force` token in the script must be immediately `--force-with-lease`.
if grep -Eq -- '(^|[^-])--force([^-]|$)' "${ROOT}/scripts/create-pr.sh"; then
  fail "static: scripts/create-pr.sh must never contain a bare --force token (only --force-with-lease is allowed)"
fi

# --- Restricted bin with a controllable fake gh ------------------------------
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git basename dirname mkdir rm cat sed tr cut grep printf date wc touch; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr view")
    [ -f "${GH_STATE:?}" ] || exit 1
    case "$*" in
      *url*)    printf 'https://example.invalid/pr/123\n' ;;
      *number*) printf '123\n' ;;
      *)        printf '123\n' ;;
    esac
    exit 0
    ;;
  "pr create")
    : > "${GH_STATE:?}"
    exit 0
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "${BIN}/gh"

# make_pr_repo <dir> <issue-pad> — feature/issue-<pad>-fixture on a bare origin.
make_pr_repo() {
  local dir="$1" pad="$2"
  mkdir -p "${dir}/scripts" "${dir}/docs"
  cp "${ROOT}/scripts/create-pr.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/review-gate.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/" 2>/dev/null || true
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign false
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  printf '# Progress\n\nbaseline\n' > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add .gitignore README.md docs/PROGRESS.md scripts
  git -C "$dir" commit -q -m initial
  git clone -q --bare "$dir" "${dir}-origin.git"
  git -C "$dir" remote add origin "${dir}-origin.git"
  git -C "$dir" checkout -q -b "feature/issue-${pad}-fixture"
  printf '# Progress\n\nissue-%s work\n' "$pad" > "${dir}/docs/PROGRESS.md"
  git -C "$dir" add docs/PROGRESS.md
  git -C "$dir" commit -q -m "issue-${pad}: feature work"
  git -C "$dir" fetch -q origin main
}

# advance_origin_main_unrelated <dir> — push a change to origin's main that
# does not collide with the branch's own commit (no textual conflict), so the
# default rebase changes the branch's SHA without hitting a merge conflict.
advance_origin_main_unrelated() {
  local dir="$1"
  local work="${dir}-mainwork"
  git clone -q "${dir}-origin.git" "$work"
  git -C "$work" config user.name "Harness Test"
  git -C "$work" config user.email "harness-test@example.invalid"
  printf 'unrelated\n' > "${work}/other.txt"
  git -C "$work" add other.txt
  git -C "$work" commit -q -m "main: unrelated change"
  git -C "$work" push -q origin main
  git -C "$dir" fetch -q origin main
}

# install_force_policy_hook <origin-git-dir> — a real pre-receive hook that
# authentically simulates a GitHub "Block force pushes" branch-protection
# rule: any non-fast-forward ref update is rejected with a message containing
# both "protected branch" and "declined"; ref creation/deletion and genuine
# fast-forward updates are allowed through untouched.
install_force_policy_hook() {
  local origin_dir="$1"
  mkdir -p "${origin_dir}/hooks"
  cat > "${origin_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
zero="0000000000000000000000000000000000000000"
while read -r old new ref; do
  [ "$old" = "$zero" ] && continue
  [ "$new" = "$zero" ] && continue
  if git merge-base --is-ancestor "$old" "$new"; then
    continue
  fi
  printf 'remote: *** this is a protected branch — non-fast-forward pushes are declined ***\n' >&2
  exit 1
done
exit 0
HOOK
  chmod +x "${origin_dir}/hooks/pre-receive"
}

# install_rulesets_protected_ref_hook <origin-git-dir> — a real pre-receive
# hook that authentically simulates a MODERN GitHub Ruleset's force-push /
# protected-ref rejection (as opposed to the legacy "protected branch" wording
# install_force_policy_hook simulates above): exact `GH013: Repository rule
# violations...` plus `Cannot update this protected ref.` plus a `push
# declined due to repository rule violations` line, and NOTHING else — no
# secret-scanning/push-protection text. This is the same underlying
# force-push-policy block as install_force_policy_hook, just in GitHub's
# current Rulesets phrasing (issue #326 security follow-up: GH013 text alone
# was being denylisted unconditionally, which meant this exact, unambiguous
# protected-ref shape never reached the fallback).
install_rulesets_protected_ref_hook() {
  local origin_dir="$1"
  mkdir -p "${origin_dir}/hooks"
  cat > "${origin_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
zero="0000000000000000000000000000000000000000"
while read -r old new ref; do
  [ "$old" = "$zero" ] && continue
  [ "$new" = "$zero" ] && continue
  if git merge-base --is-ancestor "$old" "$new"; then
    continue
  fi
  {
    printf 'remote: GH013: Repository rule violations found for %s.\n' "$ref"
    printf 'remote:\n'
    printf 'remote: - Cannot update this protected ref.\n'
    printf 'remote:\n'
    printf 'remote: push declined due to repository rule violations\n'
  } >&2
  exit 1
done
exit 0
HOOK
  chmod +x "${origin_dir}/hooks/pre-receive"
}

# install_rulesets_mixed_deny_hook <origin-git-dir> — the SAME GH013 +
# "Cannot update this protected ref" text as install_rulesets_protected_ref_hook
# above, but with an ADDITIONAL, genuinely different content-based deny
# signature (secret-scanning / push-protection text) mixed into the very same
# rejection. This is the ambiguous case the security follow-up is about: GH013
# / "repository rule violations" is the umbrella error code GitHub Rulesets
# use for MANY unrelated rule kinds (protected-ref, required-status-checks,
# secret-scanning push protection, ...), so when a genuine content-rejection
# signature is present alongside the protected-ref phrase, the deny-list must
# win — this must never be classified as a force-push-policy block.
install_rulesets_mixed_deny_hook() {
  local origin_dir="$1"
  mkdir -p "${origin_dir}/hooks"
  cat > "${origin_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
zero="0000000000000000000000000000000000000000"
while read -r old new ref; do
  [ "$old" = "$zero" ] && continue
  [ "$new" = "$zero" ] && continue
  if git merge-base --is-ancestor "$old" "$new"; then
    continue
  fi
  {
    printf 'remote: GH013: Repository rule violations found for %s.\n' "$ref"
    printf 'remote:\n'
    printf 'remote: - Cannot update this protected ref.\n'
    printf 'remote: - Push cannot contain secrets (secret scanning / push protection)\n'
    printf 'remote:\n'
    printf 'remote: push declined due to repository rule violations\n'
  } >&2
  exit 1
done
exit 0
HOOK
  chmod +x "${origin_dir}/hooks/pre-receive"
}

# run_cpr <dir> <state-suffix> <out-file> [env=val ...] -- <args...>
run_cpr() {
  local dir="$1" sfx="$2" out="$3"; shift 3
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  (cd "$dir" && env PATH="$BIN" GH_STATE="${TMP_DIR}/gh-state-${sfx}" "${envs[@]}" \
    ./scripts/create-pr.sh "$@") > "$out" 2>&1
}

# ============================================================================
# (a) Policy-blocked rejection triggers the fallback (never a hard failure)
# ============================================================================
RA="${TMP_DIR}/ra"
make_pr_repo "$RA" 326
# The branch already exists on the remote — the exact #317 precondition.
git -C "$RA" push -q origin "feature/issue-326-fixture"
TIP_ON_REMOTE_A="$(git --git-dir="${RA}-origin.git" rev-parse "refs/heads/feature/issue-326-fixture")"
# A distinct, local-only commit made right after that push and never itself
# pushed — the conductor-flagged reproduction: a clean local branch legitimately
# ahead of its own already-pushed remote tip (normal first PR-open/re-sync
# behavior) BEFORE the rebase + force-reject fallback below ever runs. The
# fallback must preserve this commit's content, not merely avoid a hard
# failure — resetting to the remote's tip instead of the pre-sync local tip
# would silently discard it.
printf 'local-only work\n' > "${RA}/local_only.txt"
git -C "$RA" add local_only.txt
git -C "$RA" commit -q -m "issue-326: local-only unpushed commit"
install_force_policy_hook "${RA}-origin.git"
advance_origin_main_unrelated "$RA"

# --- (a0) Establishing run: pre-existing, unchanged behavior — a rebase that
# changes HEAD always needs a fresh approval before push is ever attempted.
# Not itself part of this feature's contract; it is the only way to reach a
# state where the NEXT run's rebase is a no-op and gate-check passes, so the
# push (and therefore the hook) is actually reached.
(cd "$RA" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(a) setup: approve of the pre-rebase tip failed"
OUT_A0="${TMP_DIR}/a0.out"
if run_cpr "$RA" a0 "$OUT_A0" -- --title t --body b; then
  cat "$OUT_A0"; fail "(a0) establishing run: create-pr.sh must exit non-zero — the rebase changed HEAD and it is not yet approved"
fi
grep -q "has not been approved" "$OUT_A0" \
  || { cat "$OUT_A0"; fail "(a0) establishing run: must print the existing 'has not been approved' message"; }
[ "$(git --git-dir="${RA}-origin.git" rev-parse "refs/heads/feature/issue-326-fixture")" = "$TIP_ON_REMOTE_A" ] \
  || fail "(a0) establishing run: nothing may be pushed before the rebased HEAD is approved"
OWNED_REF_A="$(owned_ref_path feature/issue-326-fixture)"
git -C "$RA" rev-parse -q --verify "$OWNED_REF_A" >/dev/null 2>&1 \
  || fail "(a0) owned pre-sync ref ${OWNED_REF_A} must exist once a rebase actually changed HEAD — it is the only cross-invocation restore point for the later fallback"

# Deliberately corrupt ORIG_HEAD between the two runs: the fix under test must
# rely solely on its own owned_ref marker, never on git's own ORIG_HEAD, to
# recover the true pre-rebase tip across this approval-gate retry.
corrupt_orig_head "$RA"

# --- (a1) The interesting run: rebase no-ops (already synced from a0), gate
# passes, --force-with-lease is attempted for real and the hook rejects it.
(cd "$RA" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(a1) setup: approve of the rebased HEAD failed"
OUT_A1="${TMP_DIR}/a1.out"
if run_cpr "$RA" a1 "$OUT_A1" -- --title t --body b; then
  cat "$OUT_A1"; fail "(a1) create-pr.sh must exit non-zero — the new fallback merge HEAD is not yet approved"
fi
grep -qi 'declined\|protected branch' "$OUT_A1" \
  || { cat "$OUT_A1"; fail "(a1) the hook's force-push-policy rejection must be visible in the output"; }
grep -qi 'falling back to a non-rewriting sync' "$OUT_A1" \
  || { cat "$OUT_A1"; fail "(a1) the script must name the fallback instead of treating the rejection as fatal"; }
grep -q "has not been approved" "$OUT_A1" \
  || { cat "$OUT_A1"; fail "(a1) must print the existing 'has not been approved' message for the new fallback merge HEAD"; }
[ "$(git --git-dir="${RA}-origin.git" rev-parse "refs/heads/feature/issue-326-fixture")" = "$TIP_ON_REMOTE_A" ] \
  || fail "(a1) nothing may be pushed before the fallback merge HEAD is approved"
PARENT_COUNT_A1="$(git -C "$RA" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_A1" = "2" ] \
  || fail "(a1) HEAD must already be the fallback merge commit (two parents), got ${PARENT_COUNT_A1}"
git -C "$RA" merge-base --is-ancestor "$TIP_ON_REMOTE_A" HEAD \
  || fail "(a1) the remote's pre-fallback tip must be an ancestor of the fallback merge HEAD"
git -C "$RA" merge-base --is-ancestor origin/main HEAD \
  || fail "(a1) origin/main must be an ancestor of the fallback merge HEAD"
[ -f "${RA}/local_only.txt" ] && [ "$(cat "${RA}/local_only.txt")" = "local-only work" ] \
  || fail "(a1) the pre-existing local-only unpushed commit's content must survive the fallback (local_only.txt missing or wrong content after the reset+merge) — the fallback must restore the pre-sync LOCAL tip, not the remote tip"
git -C "$RA" rev-parse -q --verify "$OWNED_REF_A" >/dev/null 2>&1 \
  || fail "(a1) owned pre-sync ref ${OWNED_REF_A} must still exist — retained across the policy-rejection fallback until the branch push finally succeeds"

# --- (a2) Approve the fallback merge HEAD and re-run: succeeds, non-rewriting.
(cd "$RA" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(a2) setup: approve of the fallback merge HEAD failed"
OUT_A2="${TMP_DIR}/a2.out"
run_cpr "$RA" a2 "$OUT_A2" -- --title t --body b \
  || { cat "$OUT_A2"; fail "(a2) create-pr.sh must exit 0 once the fallback merge HEAD is approved"; }
grep -q "PR #123 is open" "$OUT_A2" \
  || { cat "$OUT_A2"; fail "(a2) the PR must open (fake gh pr create must have run)"; }
PARENT_COUNT_A2="$(git -C "$RA" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_A2" = "2" ] \
  || fail "(a2) final HEAD must be a merge commit (two parents), got ${PARENT_COUNT_A2}"
git -C "$RA" merge-base --is-ancestor "$TIP_ON_REMOTE_A" HEAD \
  || fail "(a2) the remote's pre-fallback tip must still be an ancestor of the final HEAD"
ORIGIN_REF_AFTER_A2="$(git --git-dir="${RA}-origin.git" rev-parse "refs/heads/feature/issue-326-fixture")"
git --git-dir="${RA}-origin.git" merge-base --is-ancestor "$TIP_ON_REMOTE_A" "$ORIGIN_REF_AFTER_A2" \
  || fail "(a2) non-rewriting proof: the bare origin's own before-ref must be an ancestor of its after-ref (history only ever extended, never overwritten)"
git --git-dir="${RA}-origin.git" cat-file -e "${ORIGIN_REF_AFTER_A2}:local_only.txt" 2>/dev/null \
  || fail "(a2) the pushed branch tree must contain local_only.txt — the pre-existing local-only commit's content must survive the fallback all the way to the remote"
LOCAL_ONLY_CONTENT_PUSHED="$(git --git-dir="${RA}-origin.git" show "${ORIGIN_REF_AFTER_A2}:local_only.txt")"
[ "$LOCAL_ONLY_CONTENT_PUSHED" = "local-only work" ] \
  || fail "(a2) local_only.txt content must survive the fallback unchanged in the pushed branch tree, got: ${LOCAL_ONLY_CONTENT_PUSHED}"
git -C "$RA" rev-parse -q --verify "$OWNED_REF_A" >/dev/null 2>&1 \
  && fail "(a2) owned pre-sync ref ${OWNED_REF_A} must be removed once the branch push finally succeeds"

# ============================================================================
# (b) Non-policy rejection stays a hard failure — never swallowed
# ============================================================================
RB="${TMP_DIR}/rb"
make_pr_repo "$RB" 327
git -C "$RB" push -q origin "feature/issue-327-fixture"
advance_origin_main_unrelated "$RB"

# --- (b0) Same pre-existing establishing run as (a0): reach a state where the
# next run's rebase is a no-op, so the actual push attempt is reached.
(cd "$RB" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(b0) setup: approve of the pre-rebase tip failed"
OUT_B0="${TMP_DIR}/b0.out"
if run_cpr "$RB" b0 "$OUT_B0" -- --title t --body b; then
  cat "$OUT_B0"; fail "(b0) establishing run: create-pr.sh must exit non-zero — the rebase changed HEAD and it is not yet approved"
fi
(cd "$RB" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(b) setup: approve of the rebased HEAD failed"
HEAD_BEFORE_B="$(git -C "$RB" rev-parse HEAD)"
# Break the PUSH url only (fetch keeps working) so the rebase step's own
# no-op still succeeds and only the actual push fails, with a generic,
# non-policy git error — never a fallback trigger.
git -C "$RB" remote set-url --push origin "${RB}-origin-missing.git"
OUT_B="${TMP_DIR}/b.out"
if run_cpr "$RB" b "$OUT_B" -- --title t --body b; then
  cat "$OUT_B"; fail "(b) create-pr.sh must exit non-zero on a genuine (non-policy) push failure"
fi
grep -qi 'does not appear to be a git repository\|could not read from remote repository' "$OUT_B" \
  || { cat "$OUT_B"; fail "(b) the raw git push failure text must be what's printed, not a fallback message"; }
grep -qi 'falling back to a non-rewriting sync' "$OUT_B" \
  && fail "(b) a non-policy rejection must never be treated as a fallback trigger: $(cat "$OUT_B")"
PARENT_COUNT_B="$(git -C "$RB" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_B" = "1" ] \
  || fail "(b) HEAD must still be the plain rebased commit (one parent), not a merge — no fallback merge must have been attempted"
[ "$(git -C "$RB" rev-parse HEAD)" = "$HEAD_BEFORE_B" ] \
  || fail "(b) HEAD must not have moved at all — no merge/reset was attempted on a genuine push failure"
[ -f "${TMP_DIR}/gh-state-b" ] \
  && fail "(b) no PR may be opened — fake gh pr create must never have run"
OWNED_REF_B="$(owned_ref_path feature/issue-327-fixture)"
git -C "$RB" rev-parse -q --verify "$OWNED_REF_B" >/dev/null 2>&1 \
  || fail "(b) owned pre-sync ref ${OWNED_REF_B} must still exist after a genuine non-policy push failure — it is cleaned up only on a successful push or an aborted rebase conflict, never on this kind of failure"

# ============================================================================
# (d) GH013 Rulesets-shaped protected-ref rejection triggers the SAME
#     owned-ref/ancestry-safe fallback as the legacy "protected branch" text
#     in (a) — a modern GitHub Ruleset's rejection, not just classic
#     branch-protection wording, must still reach the fallback (issue #326
#     security follow-up: GH013 text was being denylisted unconditionally).
# ============================================================================
RD="${TMP_DIR}/rd"
make_pr_repo "$RD" 328
git -C "$RD" push -q origin "feature/issue-328-fixture"
TIP_ON_REMOTE_D="$(git --git-dir="${RD}-origin.git" rev-parse "refs/heads/feature/issue-328-fixture")"
# Same pre-existing local-only, never-pushed commit as (a) — the fallback
# must preserve it here too, proving this is the SAME safeguard, not a
# separately (and possibly more weakly) implemented path.
printf 'local-only work\n' > "${RD}/local_only.txt"
git -C "$RD" add local_only.txt
git -C "$RD" commit -q -m "issue-328: local-only unpushed commit"
install_rulesets_protected_ref_hook "${RD}-origin.git"
advance_origin_main_unrelated "$RD"

# --- (d0) Same pre-existing establishing run as (a0)/(b0).
(cd "$RD" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(d0) setup: approve of the pre-rebase tip failed"
OUT_D0="${TMP_DIR}/d0.out"
if run_cpr "$RD" d0 "$OUT_D0" -- --title t --body b; then
  cat "$OUT_D0"; fail "(d0) establishing run: create-pr.sh must exit non-zero — the rebase changed HEAD and it is not yet approved"
fi
[ "$(git --git-dir="${RD}-origin.git" rev-parse "refs/heads/feature/issue-328-fixture")" = "$TIP_ON_REMOTE_D" ] \
  || fail "(d0) establishing run: nothing may be pushed before the rebased HEAD is approved"

# --- (d1) The interesting run: rebase no-ops, gate passes, --force-with-lease
# is attempted for real and the GH013 Rulesets hook rejects it. THIS is the
# RED assertion against the unmodified classifier: today GH013 is on the
# unconditional deny-list, so this exact, unambiguous protected-ref shape is
# (wrongly) treated as a hard failure instead of reaching the fallback.
(cd "$RD" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(d1) setup: approve of the rebased HEAD failed"
OUT_D1="${TMP_DIR}/d1.out"
if run_cpr "$RD" d1 "$OUT_D1" -- --title t --body b; then
  cat "$OUT_D1"; fail "(d1) create-pr.sh must exit non-zero — the new fallback merge HEAD is not yet approved"
fi
grep -qi 'GH013' "$OUT_D1" \
  || { cat "$OUT_D1"; fail "(d1) the hook's GH013 Rulesets rejection text must be visible in the output"; }
grep -qi 'cannot update this protected ref' "$OUT_D1" \
  || { cat "$OUT_D1"; fail "(d1) the hook's 'Cannot update this protected ref' text must be visible in the output"; }
grep -qi 'falling back to a non-rewriting sync' "$OUT_D1" \
  || { cat "$OUT_D1"; fail "(d1) a GH013 Rulesets protected-ref rejection (exact GH013/repository rule violations + Cannot update this protected ref, no content-rejection signature) must trigger the SAME fallback as the legacy 'protected branch' text in (a) — got: $(cat "$OUT_D1")"; }
grep -q "has not been approved" "$OUT_D1" \
  || { cat "$OUT_D1"; fail "(d1) must print the existing 'has not been approved' message for the new fallback merge HEAD"; }
[ "$(git --git-dir="${RD}-origin.git" rev-parse "refs/heads/feature/issue-328-fixture")" = "$TIP_ON_REMOTE_D" ] \
  || fail "(d1) nothing may be pushed before the fallback merge HEAD is approved"
PARENT_COUNT_D1="$(git -C "$RD" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_D1" = "2" ] \
  || fail "(d1) HEAD must already be the fallback merge commit (two parents), got ${PARENT_COUNT_D1}"
git -C "$RD" merge-base --is-ancestor "$TIP_ON_REMOTE_D" HEAD \
  || fail "(d1) the remote's pre-fallback tip must be an ancestor of the fallback merge HEAD"
git -C "$RD" merge-base --is-ancestor origin/main HEAD \
  || fail "(d1) origin/main must be an ancestor of the fallback merge HEAD"
[ -f "${RD}/local_only.txt" ] && [ "$(cat "${RD}/local_only.txt")" = "local-only work" ] \
  || fail "(d1) the pre-existing local-only unpushed commit's content must survive the GH013 Rulesets fallback — the fallback must restore the pre-sync LOCAL tip, not the remote tip"
OWNED_REF_D="$(owned_ref_path feature/issue-328-fixture)"
git -C "$RD" rev-parse -q --verify "$OWNED_REF_D" >/dev/null 2>&1 \
  || fail "(d1) owned pre-sync ref ${OWNED_REF_D} must still exist — retained across the GH013 Rulesets fallback until the branch push finally succeeds"

# --- (d2) Approve the fallback merge HEAD and re-run: succeeds, non-rewriting.
(cd "$RD" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(d2) setup: approve of the fallback merge HEAD failed"
OUT_D2="${TMP_DIR}/d2.out"
run_cpr "$RD" d2 "$OUT_D2" -- --title t --body b \
  || { cat "$OUT_D2"; fail "(d2) create-pr.sh must exit 0 once the fallback merge HEAD is approved"; }
grep -q "PR #123 is open" "$OUT_D2" \
  || { cat "$OUT_D2"; fail "(d2) the PR must open (fake gh pr create must have run)"; }
PARENT_COUNT_D2="$(git -C "$RD" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_D2" = "2" ] \
  || fail "(d2) final HEAD must be a merge commit (two parents), got ${PARENT_COUNT_D2}"
ORIGIN_REF_AFTER_D2="$(git --git-dir="${RD}-origin.git" rev-parse "refs/heads/feature/issue-328-fixture")"
git --git-dir="${RD}-origin.git" merge-base --is-ancestor "$TIP_ON_REMOTE_D" "$ORIGIN_REF_AFTER_D2" \
  || fail "(d2) non-rewriting proof: the bare origin's own before-ref must be an ancestor of its after-ref (history only ever extended, never overwritten)"
git --git-dir="${RD}-origin.git" cat-file -e "${ORIGIN_REF_AFTER_D2}:local_only.txt" 2>/dev/null \
  || fail "(d2) the pushed branch tree must contain local_only.txt — the pre-existing local-only commit's content must survive the fallback all the way to the remote"
LOCAL_ONLY_CONTENT_PUSHED_D="$(git --git-dir="${RD}-origin.git" show "${ORIGIN_REF_AFTER_D2}:local_only.txt")"
[ "$LOCAL_ONLY_CONTENT_PUSHED_D" = "local-only work" ] \
  || fail "(d2) local_only.txt content must survive the fallback unchanged in the pushed branch tree, got: ${LOCAL_ONLY_CONTENT_PUSHED_D}"
git -C "$RD" rev-parse -q --verify "$OWNED_REF_D" >/dev/null 2>&1 \
  && fail "(d2) owned pre-sync ref ${OWNED_REF_D} must be removed once the branch push finally succeeds"

# ============================================================================
# (e) GH013/protected-ref text MIXED with a genuine content-based deny
#     signature (secret scanning / push protection) stays a hard failure —
#     the deny-list must win on overlap even when the protected-ref phrase is
#     also present in the very same rejection (issue #326 security follow-up:
#     GH013 is the umbrella error code for many unrelated GitHub Ruleset
#     kinds, so the protected-ref pairing alone must not be broadly allowed).
# ============================================================================
RE="${TMP_DIR}/re"
make_pr_repo "$RE" 329
git -C "$RE" push -q origin "feature/issue-329-fixture"
TIP_ON_REMOTE_E="$(git --git-dir="${RE}-origin.git" rev-parse "refs/heads/feature/issue-329-fixture")"
install_rulesets_mixed_deny_hook "${RE}-origin.git"
advance_origin_main_unrelated "$RE"

# --- (e0) Same pre-existing establishing run as (a0)/(b0)/(d0).
(cd "$RE" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(e0) setup: approve of the pre-rebase tip failed"
OUT_E0="${TMP_DIR}/e0.out"
if run_cpr "$RE" e0 "$OUT_E0" -- --title t --body b; then
  cat "$OUT_E0"; fail "(e0) establishing run: create-pr.sh must exit non-zero — the rebase changed HEAD and it is not yet approved"
fi

# --- (e) The interesting run: rebase no-ops, gate passes, --force-with-lease
# is attempted for real and the mixed GH013+secret-scanning hook rejects it.
# This must stay a hard failure — never swallowed as a fallback trigger.
(cd "$RE" && PATH="$BIN" ./scripts/review-gate.sh approve) >/dev/null 2>&1 \
  || fail "(e) setup: approve of the rebased HEAD failed"
HEAD_BEFORE_E="$(git -C "$RE" rev-parse HEAD)"
OUT_E="${TMP_DIR}/e.out"
if run_cpr "$RE" e "$OUT_E" -- --title t --body b; then
  cat "$OUT_E"; fail "(e) create-pr.sh must exit non-zero — GH013/protected-ref text mixed with a secret-scanning/push-protection signature must never be swallowed as a fallback trigger"
fi
grep -qi 'GH013' "$OUT_E" \
  || { cat "$OUT_E"; fail "(e) the raw GH013 rejection text must be what's printed, not a fallback message"; }
grep -qi 'secret' "$OUT_E" \
  || { cat "$OUT_E"; fail "(e) the raw secret-scanning/push-protection text must be what's printed, not a fallback message"; }
grep -qi 'falling back to a non-rewriting sync' "$OUT_E" \
  && fail "(e) deny-list must win: GH013 + protected-ref text mixed with a secret-scanning/push-protection signature must never trigger the fallback: $(cat "$OUT_E")"
PARENT_COUNT_E="$(git -C "$RE" show -s --format='%P' HEAD | wc -w | tr -d '[:space:]')"
[ "$PARENT_COUNT_E" = "1" ] \
  || fail "(e) HEAD must still be the plain rebased commit (one parent), not a merge — no fallback merge must have been attempted"
[ "$(git -C "$RE" rev-parse HEAD)" = "$HEAD_BEFORE_E" ] \
  || fail "(e) HEAD must not have moved at all — no reset/merge was attempted on this hard failure"
[ "$(git --git-dir="${RE}-origin.git" rev-parse "refs/heads/feature/issue-329-fixture")" = "$TIP_ON_REMOTE_E" ] \
  || fail "(e) the remote branch ref must not have moved — nothing may be pushed on a hard failure"
[ -f "${TMP_DIR}/gh-state-e" ] \
  && fail "(e) no PR may be opened — fake gh pr create must never have run"
OWNED_REF_E="$(owned_ref_path feature/issue-329-fixture)"
git -C "$RE" rev-parse -q --verify "$OWNED_REF_E" >/dev/null 2>&1 \
  || fail "(e) owned pre-sync ref ${OWNED_REF_E} must still exist after a genuine hard-failure rejection — it is cleaned up only on a successful push or an aborted rebase conflict, never on this kind of failure"

printf 'create-pr force-reject fallback sensor passed\n'
