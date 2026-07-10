#!/usr/bin/env bash
# start-issue.sh — begin work on a GitHub issue in an isolated git worktree.
#
# Usage:
#   ./scripts/start-issue.sh 1
#   ./scripts/start-issue.sh ISSUE=1
#   ./scripts/start-issue.sh ISSUE=1 SLUG=custom-slug
#
# Flow (the harness start-of-session ritual, mechanised):
#   1. Run ./scripts/init.sh; ABORT if the environment is not green. A worktree is only
#      created on top of a healthy environment. (Set SKIP_INIT=1 to bypass — for
#      scripted tests only; it defeats the purpose otherwise.)
#   2. Derive a slug from the issue title (gh) → branch feature/issue-NN-<slug>.
#   3. Create a worktree at <repo>-worktrees/issue-NN on that branch (off main).
#   4. Scaffold .copilot-tracking/issues/issue-NN/ (feature_list.json, progress.md)
#      if missing.
#   5. Print the cd path + next steps. Idempotent: never clobbers an existing
#      worktree or branch.
#
# Exit codes: 0 ready · 1 usage / precondition failure

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/issue-lib.sh
source "${SCRIPT_DIR}/issue-lib.sh"

# --- Tracing (issue #94, plan D5) --------------------------------------------
# Guarded source: a missing trace-lib.sh must never break the lifecycle.
if [ -f "${SCRIPT_DIR}/trace-lib.sh" ]; then
  # shellcheck source=scripts/trace-lib.sh
  source "${SCRIPT_DIR}/trace-lib.sh"
fi
if ! declare -F trace_span >/dev/null 2>&1; then
  TRACE_NOOP_WARNED=0
  trace_span() {
    if [ "${TRACE_NOOP_WARNED}" = "0" ]; then
      printf 'start-issue: warning: scripts/trace-lib.sh not found — trace spans disabled\n' >&2
      TRACE_NOOP_WARNED=1
    fi
    return 0
  }
  trace_now_ms() { printf '%s000' "$(date +%s 2>/dev/null || printf '0')"; }
  trace_lifecycle_init() { :; }
  trace_lifecycle_arm() { :; }
fi

# Emit a JSON-quoted string literal for arbitrary input (including titles that
# carry double-quotes, backslashes, or newlines), so the scaffolded
# feature_list.json is always valid JSON. Prefers jq; falls back to a
# hand-rolled escaper when jq is unavailable.
json_string() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
    return
  fi
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Terminal worktree_create lifecycle span via the shared EXIT-trap helper
# (issue #213 P-1, trace_lifecycle_init): once armed at the worktree stage
# below, every exit path — success, reuse, or a failed `git worktree add` —
# emits exactly one worktree_create span with the real exit status and duration,
# without touching any exit site. Late-bound attrs (branch/worktree/base_ref and
# the reuse/scaffold flags) are gathered at exit time by trace__start_issue_attrs.
WORKTREE_REUSED=false
SCAFFOLDED=false
trace__start_issue_attrs() {
  printf 'harness.branch=%s\n' "${BRANCH:-}"
  printf 'harness.worktree=%s\n' "${WORKTREE_DIR:-}"
  printf 'harness.base_ref=%s\n' "${base_ref:-}"
  printf 'harness.worktree_reused=%s\n' "${WORKTREE_REUSED}"
  printf 'harness.scaffolded=%s\n' "${SCAFFOLDED}"
}
trace_lifecycle_init worktree_create trace__start_issue_attrs

# --- Parse args -------------------------------------------------------------
NUM_ARG="" SLUG_ARG=""
for arg in "$@"; do
  case "$arg" in
    SLUG=*) SLUG_ARG="${arg#SLUG=}" ;;
    *)      NUM_ARG="$arg" ;;
  esac
done
if [ -z "$NUM_ARG" ]; then
  red "usage: ./scripts/start-issue.sh <issue-number> [SLUG=custom-slug]"
  exit 1
fi
ISSUE_NUM="$(issue_parse_number "$NUM_ARG")"

# start-issue runs from the main checkout on branch main, so branch/worktree
# issue resolution cannot work — export the parsed number (plan D6).
export TRACE_ISSUE="$ISSUE_NUM"

ROOT="$(issue_repo_root)"
cd "$ROOT"

if [ ! -f "${ROOT}/.github/hooks/harness-trace.json" ]; then
  yellow "⚠ tracing hooks are not configured (${ROOT}/.github/hooks/harness-trace.json missing); runtime spans are only captured when the session is launched from the repo root (a trusted folder containing .github/hooks/), otherwise this is a dark run." >&2
fi

# Refuse to run from inside a linked worktree — start-issue operates on main.
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  red "✗ run start-issue.sh from the main checkout, not from a worktree."
  exit 1
fi

# --- 1. Preflight (init.sh) -------------------------------------------------
TRACE_T0="$(trace_now_ms)"
if [ "${SKIP_INIT:-0}" = "1" ]; then
  bold "==> Skipping init.sh (SKIP_INIT=1)"
  trace_span lifecycle \
    "harness.lifecycle_step=preflight" \
    "harness.outcome=pass" \
    "harness.exit_status=0" \
    "harness.duration_ms=$(( $(trace_now_ms) - TRACE_T0 ))" \
    "harness.preflight_skipped=true"
else
  bold "==> Running preflight (./scripts/init.sh)"
  preflight_rc=0
  "${ROOT}/scripts/init.sh" || preflight_rc=$?
  if [ "$preflight_rc" -ne 0 ]; then
    trace_span lifecycle \
      "harness.lifecycle_step=preflight" \
      "harness.outcome=fail" \
      "harness.exit_status=${preflight_rc}" \
      "harness.duration_ms=$(( $(trace_now_ms) - TRACE_T0 ))"
    red "✗ Preflight failed — fix the environment before starting an issue."
    exit 1
  fi
  trace_span lifecycle \
    "harness.lifecycle_step=preflight" \
    "harness.outcome=pass" \
    "harness.exit_status=0" \
    "harness.duration_ms=$(( $(trace_now_ms) - TRACE_T0 ))"
fi

# --- 2. Resolve naming ------------------------------------------------------
resolve_issue_env "$ISSUE_NUM" "$SLUG_ARG"
bold "==> Issue ${ISSUE_NUM}"
echo "  branch:   ${BRANCH}"
echo "  worktree: ${WORKTREE_DIR}"

# --- 3. Create worktree + branch (non-destructive) --------------------------
trace_lifecycle_arm
if [ -e "$WORKTREE_DIR" ]; then
  WORKTREE_REUSED=true
  green "✓ Worktree already exists — reusing it (no changes made)."
  echo
  echo "  cd ${WORKTREE_DIR}"
  exit 0
fi

base_ref=main
if git show-ref --verify --quiet refs/remotes/origin/main; then
  base_ref=origin/main
fi

if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  echo "  branch ${BRANCH} already exists — attaching worktree to it."
  git worktree add "$WORKTREE_DIR" "$BRANCH"
else
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$base_ref"
fi
green "✓ Worktree created at ${WORKTREE_DIR} (base: ${base_ref})"

# --- 3b. Active-issue marker (issue #216, P-5) ------------------------------
# Record this issue as the sole live window in a tiny per-issue marker file the
# copilot trace hook reads directly, so span attribution no longer depends on
# the O(N) interval scan for the common single-issue case. Content is the
# whole-second UTC window-start ISO timestamp (comparable to the hook's
# normalized payload timestamps). Best-effort: a marker-write failure must never
# break the lifecycle. finish-issue.sh sweeps our own marker at closeout.
if marker_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" && [ -n "$marker_ts" ]; then
  if mkdir -p "${ROOT}/.copilot-tracking/active-issues" 2>/dev/null \
      && printf '%s' "$marker_ts" > "${ROOT}/.copilot-tracking/active-issues/${ISSUE_NUM}" 2>/dev/null; then
    green "✓ Recorded active-issue marker for issue ${ISSUE_NUM}"
  else
    yellow "⚠ could not record active-issue marker — continuing (hook falls back to interval scan)"
  fi
fi

# --- 4. Scaffold per-issue tracking (gitignored) ----------------------------
if [ ! -d "$TRACKING_DIR" ]; then
  SCAFFOLDED=true
  mkdir -p "$TRACKING_DIR"
  ISSUE_TITLE_RAW="$(gh issue view "$ISSUE_NUM" --json title -q .title 2>/dev/null || true)"
  [ -n "$ISSUE_TITLE_RAW" ] || ISSUE_TITLE_RAW="issue ${ISSUE_NUM}"
  ISSUE_TITLE_JSON="$(json_string "$ISSUE_TITLE_RAW")"
  cat > "${TRACKING_DIR}/feature_list.json" <<JSON
{
  "issue": ${ISSUE_NUM},
  "title": ${ISSUE_TITLE_JSON},
  "branch": "${BRANCH}",
  "feature_schema": {
    "id": "string",
    "title": "string",
    "steps": [],
    "passes": false,
    "regression_sensor": null,
    "e2e_sensor": null,
    "blocked_on": null,
    "verification": null
  },
  "features": []
}
JSON
  cat > "${TRACKING_DIR}/progress.md" <<MD
# Issue ${ISSUE_NUM} progress

Status: not started.

- Branch: \`${BRANCH}\`
- Worktree: \`${WORKTREE_DIR}\`

## Action Log

- _Record conductor handbacks, subagent actions, review verdicts, and recovery notes here._

The **conductor authors** \`feature_list.json\` — but only *after* the
\`planning-subagent\` plan is approved and the human-input gate has resolved
every Open Question. The planning-subagent never writes this breakdown. Once it
is populated (each feature carrying its \`regression_sensor\`/\`e2e_sensor\`),
work one \`passes:false\` item at a time (see harness §3 and docs/HARNESS.md
step 4).
MD
  green "✓ Scaffolded ${TRACKING_DIR#"$WORKTREE_DIR"/} (feature_list.json, progress.md)"
else
  green "✓ Tracking dir already present — left untouched."
fi

# --- 5. Seed developer-local hook config ------------------------------------
# The Copilot trace hook config lives at ${ROOT}/.github/hooks/harness-trace.json.
# It is a gitignored, developer-local file, so `git worktree add` never carries
# it into the new worktree. Copy it in here. This is a purely local operation:
# it never contacts a remote, and it never fails the lifecycle — a missing source
# file is normal (not every checkout configures the hook) and is skipped silently.
# Runs ONLY on fresh worktree creation; the reuse path exits earlier (section 3)
# and so never reaches this block, leaving any worktree-local hook config intact.
HOOK_SRC="${ROOT}/.github/hooks/harness-trace.json"
HOOK_DST="${WORKTREE_DIR}/.github/hooks/harness-trace.json"
if [ -f "$HOOK_SRC" ]; then
  mkdir -p "$(dirname "$HOOK_DST")"
  cp -p "$HOOK_SRC" "$HOOK_DST"
  green "✓ Seeded developer-local hook config (.github/hooks/harness-trace.json)"
fi

# --- 6. Next steps ----------------------------------------------------------
echo
bold "Ready. Start working in the worktree:"
echo "  cd ${WORKTREE_DIR}"
echo "  gh issue view ${ISSUE_NUM} --comments   # single source of truth"
echo "  # plan first; after the plan + human-input gate, the conductor authors ${TRACKING_DIR#"$WORKTREE_DIR"/}/feature_list.json, then pick one passes:false feature"
