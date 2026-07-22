#!/usr/bin/env bash
# test_boundary_gates_research_inventory.sh — structural regression sensor for
# issue #86 feature `boundary-inventory`.
#
# Contract under test (PINNED HERE as the executable spec): the boundary-gates
# research report must exist and carry, in ONE authoritative `## Boundary
# Inventory` section, the inventory of the lifecycle's irreversible/expensive
# boundaries. For each boundary the section must name the irreversible action,
# its motivating incident, its evidence predicate over `trace.jsonl`, and the
# current gate coverage/gap. The report is a research/proposal doc following the
# house convention (H1 title, an Executive-summary section, then numbered
# sections). This issue is research-only: it PROPOSES contract/gate changes; it
# does not implement them, so no lifecycle script or `docs/harness-contract.yml`
# behavior is touched.
#
#   docs/boundary-gates-research.md must:
#   1. Have an H1 title and an `## Executive summary` section.
#   2. Carry the `## Boundary Inventory` section exactly ONCE.
#   3. Inside that section, name the seven boundaries — PR create, PR merge,
#      Closeout conclusion, Worktree teardown, Issue close, Branch deletion,
#      plus the future Deploy / Terraform apply boundary named as future work —
#      each with its motivating incident ref (#167, #299, #316, #321, #323,
#      #328), the evidence predicate tokens over `trace.jsonl` (merge_state,
#      MERGED, merge_sha, write-once, and the teardown pr_merge
#      optional/permissive cross-check leg), and the coverage/gap classification
#      words (hard, warn-only, soft/recoverable for branch deletion).
#   4. State the thesis: process integrity comes from deterministic gates
#      verifying evidence in `trace.jsonl`, not from model compliance or wrapper
#      exit codes.
#
# The assertions are scoped to the single `## Boundary Inventory` section (sed
# between its `## ` heading and the next `## ` heading), and each boundary's
# incident/predicate/coverage token is further bound to its OWN table row (the
# single physical `|`-line whose first cell names the boundary). This gives the
# pins teeth twice over: reverting the section, or swapping one row's incident
# or predicate token into another row, turns the gate RED even though the same
# words still appear elsewhere in the flattened section.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the report does not yet carry the boundary inventory).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/boundary-gates-research.md"
HEADING='## Boundary Inventory'

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# ==============================================================================
# RED gate: the report must exist before content pins can run.
# ==============================================================================
if [ ! -f "${DOC}" ]; then
  fail "boundary-gates research report not found (${DOC}) — feature boundary-inventory (issue #86) is not implemented yet"
  printf '\n%d boundary-inventory contract violation(s).\n' "${fails}" >&2
  exit 1
fi

# House-convention scaffold: an H1 title and an Executive summary section.
grep -qE '^# [^[:space:]]' "${DOC}" \
  || fail "report must carry an H1 title (house convention)"
grep -qF '## Executive summary' "${DOC}" \
  || fail "report must carry an '## Executive summary' section (house convention)"

# The authoritative section must exist exactly once (one place).
heading_count="$(grep -cF "${HEADING}" "${DOC}" || true)"
if [ "${heading_count}" -eq 0 ]; then
  fail "report must carry the '${HEADING}' section (inventory documented in one place)"
elif [ "${heading_count}" -gt 1 ]; then
  fail "report must carry the '${HEADING}' section exactly ONCE (found ${heading_count})"
fi

# Scope to the inventory section: from its heading down to the next `## `
# heading. A newline-flattened copy lets multi-word phrase pins survive wrapping.
section="$(sed -n "/${HEADING}/,/^## /p" "${DOC}")"
if [ -z "${section}" ]; then
  fail "could not locate the boundary inventory section body"
  printf '\n%d boundary-inventory contract violation(s).\n' "${fails}" >&2
  exit 1
fi
flat="$(printf '%s\n' "${section}" | tr '\n' ' ')"

pin() { # pin <needle> <message>  (case-insensitive fixed-string)
  grep -qiF "$1" <<<"${flat}" || fail "$2"
}
pin_cs() { # pin_cs <needle> <message>  (case-sensitive fixed-string — token teeth)
  grep -qF "$1" <<<"${flat}" || fail "$2"
}

# ==============================================================================
# 1. The five boundaries by name (section-scoped existence).
# ==============================================================================
pin 'PR create'            "inventory must name the PR create boundary"
pin 'PR merge'             "inventory must name the PR merge boundary"
pin 'Closeout conclusion'  "inventory must name the Closeout conclusion boundary"
pin 'Worktree teardown'    "inventory must name the Worktree teardown boundary"
pin 'Issue close'          "inventory must name the Issue close boundary"
pin 'Branch deletion'      "inventory must name the Branch deletion boundary"
grep -qiE 'Deploy|Terraform apply' <<<"${flat}" \
  || fail "inventory must name the future Deploy / Terraform apply boundary"
pin 'future' "inventory must name Deploy / Terraform apply as FUTURE work, not an implemented gate"

# Section-scoped predicate/thesis anchors kept as coarse existence pins; the
# ROW-scoped binding in section 6 is what gives them teeth against swaps.
pin_cs 'trace.jsonl'   "inventory must state predicates over trace.jsonl"
pin 'write-once'       "inventory closeout predicate must state the write-once terminal conclusion"
pin 'hard'             "inventory must classify gate coverage as hard where it is enforced"
pin 'warn-only'        "inventory must flag the warn-only gaps"

# ==============================================================================
# 2. The thesis: gates verify recorded evidence, not model compliance / exit
#    codes. Evidence sources are stated as plural (not trace.jsonl alone).
# ==============================================================================
pin 'deterministic gates' "inventory must state the deterministic-gates thesis"
pin 'model compliance'    "inventory thesis must contrast gates with model compliance"
pin 'exit code'           "inventory thesis must contrast gates with wrapper exit codes"

# ==============================================================================
# 2b. EXEC-SUMMARY-scoped consolidation claim (finding 3 teeth). The executive
#     summary's consolidation paragraph must describe TWO DISTINCT kinds of
#     duplication, not conflate them: (a) the three near-identical review-gate
#     functions each RE-SHELL OUT to check-trace-consistency.sh and grep a named
#     VIOLATION; (b) finish__pr_merge_evidence_ok is INLINE jq in finish-lib.sh
#     — it does NOT re-shell that checker — duplicated inline predicate logic.
#     Reverting to the false "finish__pr_merge_evidence_ok re-shells to
#     check-trace-consistency" claim drops the 'inline predicate logic' /
#     'two distinct' anchors and turns the gate RED.
# ==============================================================================
exec_section="$(sed -n '/## Executive summary/,/^## /p' "${DOC}")"
if [ -z "${exec_section}" ]; then
  fail "could not locate the '## Executive summary' section body"
else
  exec_flat="$(printf '%s\n' "${exec_section}" | tr '\n' ' ')"
  epin() { # epin <needle> <message>  (case-insensitive fixed-string)
    grep -qiF "$1" <<<"${exec_flat}" || fail "$2"
  }
  epin_cs() { # epin_cs <needle> <message>  (case-sensitive — token teeth)
    grep -qF "$1" <<<"${exec_flat}" || fail "$2"
  }
  epin 'two distinct' "exec summary consolidation must separate the TWO DISTINCT kinds of duplication"
  epin 'inline predicate logic' "exec summary must describe finish__pr_merge_evidence_ok as duplicated INLINE PREDICATE LOGIC"
  epin_cs 'finish__pr_merge_evidence_ok' "exec summary must name finish__pr_merge_evidence_ok as the inline-jq predicate"
  epin_cs 'inline' "exec summary must state the merge-evidence predicate is INLINE (not a re-shell)"
  epin_cs 'jq' "exec summary must state finish__pr_merge_evidence_ok is inline jq"
  epin_cs 'red_first_evidence_gate' "exec summary must name the review-gate functions that DO re-shell the checker"
  epin 're-shell' "exec summary must state the review-gate functions RE-SHELL to check-trace-consistency (separate mechanism)"
  epin_cs 'check-trace-consistency.sh' "exec summary must name check-trace-consistency.sh as the re-shelled checker (review-gate only)"
fi

# ==============================================================================
# 3. ROW-scoped binding (defect-1 teeth). Each boundary's motivating incident,
#    evidence predicate, and coverage/gap must live IN ITS OWN table row, so
#    swapping an incident or predicate between rows turns the gate RED even
#    though the same tokens still appear somewhere in the flattened section.
#
#    Table rows are single physical lines beginning with `|`; `row` extracts the
#    one row whose first cell carries the bold boundary label.
# ==============================================================================
row() { # row <bold-label-fragment> -> the inventory table row line for it
  grep -E '^\|' <<<"${section}" | grep -F "**$1" | head -n1
}
in_row() { # in_row <row> <needle> <message>  (case-insensitive fixed-string)
  { [ -n "$1" ] && grep -qiF "$2" <<<"$1"; } || fail "$3"
}
in_row_cs() { # in_row_cs <row> <needle> <message>  (case-sensitive — token teeth)
  { [ -n "$1" ] && grep -qF "$2" <<<"$1"; } || fail "$3"
}

r_create="$(row 'PR create')"
[ -n "${r_create}" ] || fail "could not extract the PR create inventory row"
in_row_cs "${r_create}" '#299'         "PR create row must carry its OWN incident #299"
in_row    "${r_create}" 'review_gate'  "PR create row must carry its OWN review-gate evidence predicate"
in_row    "${r_create}" 'hard'         "PR create row must classify its OWN coverage as hard"
# Defect-1 (finding 1): the HARD predicate is the LOCAL approved-head marker ==
# current HEAD; the matching review_gate_approve TRACE span is advisory/optional
# — separate the hard marker predicate from the advisory trace gap IN the row.
in_row    "${r_create}" 'approved-head marker' "PR create row must name the LOCAL approved-head marker == HEAD as the hard predicate"
in_row    "${r_create}" 'advisory'     "PR create row must state the review_gate_approve trace span is only an ADVISORY cross-check"
in_row    "${r_create}" 'review_sha_mismatch' "PR create row must state an ABSENT approval span is NOTE-skipped (review_sha_mismatch check skipped)"
in_row    "${r_create}" 'warn-only'    "PR create row must state trace consistency is WARN-ONLY by default (advisory), separate from the hard marker"

r_merge="$(row 'PR merge')"
[ -n "${r_merge}" ] || fail "could not extract the PR merge inventory row"
in_row_cs "${r_merge}" '#328'          "PR merge row must carry its OWN incident #328"
in_row_cs "${r_merge}" 'merge_state'   "PR merge row predicate must reference merge_state"
in_row_cs "${r_merge}" 'MERGED'        "PR merge row predicate must require the MERGED state"
in_row_cs "${r_merge}" 'merge_sha'     "PR merge row predicate must require a non-empty merge_sha"
in_row    "${r_merge}" 'hard'          "PR merge row must classify its OWN coverage as hard"

r_close="$(row 'Closeout conclusion')"
[ -n "${r_close}" ] || fail "could not extract the Closeout conclusion inventory row"
in_row_cs "${r_close}" '#323'          "Closeout row must carry its OWN incident #323"
in_row    "${r_close}" 'write-once'    "Closeout row predicate must state write-once first-write semantics"
in_row    "${r_close}" 'idempotent'    "Closeout row must state same-value idempotence (accurate semantics, not 'exactly once')"
in_row    "${r_close}" 'duplicate'     "Closeout row must name duplicate-line detection as a gap"
in_row    "${r_close}" 'hard'          "Closeout row must classify first-write coverage as hard"

r_teardown="$(row 'Worktree teardown')"
[ -n "${r_teardown}" ] || fail "could not extract the Worktree teardown inventory row"
in_row_cs "${r_teardown}" '#316'       "Teardown row must carry its OWN incident #316"
in_row_cs "${r_teardown}" '#321'       "Teardown row must carry its OWN incident #321"
in_row    "${r_teardown}" 'gh pr list' "Teardown row must state the LIVE GitHub merged-PR evidence source"
in_row    "${r_teardown}" 'live'       "Teardown row must state that the merged-PR fact is queried LIVE (not from trace.jsonl)"
in_row    "${r_teardown}" 'ABANDONED'  "Teardown row predicate must include the ABANDONED=1 authority"
in_row_cs "${r_teardown}" 'trace.jsonl' "Teardown row must bind its OWN trace.jsonl cross-check leg"
in_row_cs "${r_teardown}" 'pr_merge'   "Teardown row must name the pr_merge span as the cross-check leg"
in_row    "${r_teardown}" 'optional'   "Teardown row must state the trace.jsonl pr_merge leg is OPTIONAL"
in_row    "${r_teardown}" 'permissive' "Teardown row must state the pr_merge cross-check is PERMISSIVE (passes when trace/jq absent)"
in_row    "${r_teardown}" 'warn-only'  "Teardown row must flag the warn-only / permissive trace leg gap"

r_issue_close="$(row 'Issue close')"
[ -n "${r_issue_close}" ] || fail "could not extract the Issue close inventory row"
in_row_cs "${r_issue_close}" '#316'         "Issue close row must carry its OWN incident #316 (manually closed without a PR, then reopened)"
in_row    "${r_issue_close}" 'GitHub issue state' "Issue close row must name its OWN irreversible action (external GitHub issue state transition to closed)"
in_row    "${r_issue_close}" 'manual'        "Issue close row must state the closure can be manual (or via PR keyword)"
in_row    "${r_issue_close}" 'merged PR'     "Issue close row must state its OWN desired evidence predicate: an authoritative merged PR / merge trace"
in_row    "${r_issue_close}" 'terminal closeout evidence' "Issue close desired predicate must require TERMINAL CLOSEOUT EVIDENCE (merged or governed abandoned), not a nonexistent closed conclusion"
in_row    "${r_issue_close}" 'abandon'       "Issue close row must accept a GOVERNED ABANDONMENT (ABANDONED=1) as terminal closeout evidence"
in_row    "${r_issue_close}" 'CLOSED'        "Issue close predicate must gate the external GitHub issue state transition to CLOSED (the harness records only merged/abandoned conclusions, never a closed one)"
in_row    "${r_issue_close}" 'no direct harness issue-close gate' "Issue close row must state the gap: there is no direct harness issue-close gate"
in_row    "${r_issue_close}" 'cannot prevent' "Issue close row must state finish blocks teardown but cannot prevent a manual/GitHub closure"
# Finding 2: the DESIRED predicate must require a RECORDED UNIQUE TERMINAL
# `Conclusion: merged|abandoned` line before external CLOSED — not merely the
# merged-PR/ABANDONED input — and must name the duplicate-conclusion GAP:
# finish__atomic_conclusion reads only the FIRST Conclusion line, so a duplicate
# terminal conclusion is undetected and the uniqueness predicate inherits it.
in_row_cs "${r_issue_close}" 'Conclusion: merged|abandoned' "Issue close desired predicate must require a recorded terminal Conclusion: merged|abandoned line"
in_row    "${r_issue_close}" 'recorded unique terminal' "Issue close predicate must require a RECORDED UNIQUE TERMINAL conclusion, not merely the merged-PR/ABANDONED input"
in_row    "${r_issue_close}" 'not merely' "Issue close predicate must state it is NOT MERELY the merged-PR/ABANDONED input"
in_row    "${r_issue_close}" 'input' "Issue close predicate must contrast the recorded conclusion with the merged-PR/ABANDONED input"
in_row_cs "${r_issue_close}" 'finish__atomic_conclusion' "Issue close row must name finish__atomic_conclusion reading only the first Conclusion line"
in_row    "${r_issue_close}" 'duplicate' "Issue close row must state duplicate-conclusion detection is an unmet GAP"
in_row    "${r_issue_close}" 'inherits' "Issue close uniqueness predicate must state it INHERITS the duplicate-conclusion gap from the Closeout row"

r_branch_deletion="$(row 'Branch deletion')"
[ -n "${r_branch_deletion}" ] || fail "could not extract the Branch deletion inventory row"
in_row_cs "${r_branch_deletion}" '#167'                 "Branch deletion row must carry its OWN incident #167 (worktree-cleanup)"
in_row    "${r_branch_deletion}" 'git push origin --delete' "Branch deletion row must name its OWN irreversible action (git push origin --delete)"
in_row    "${r_branch_deletion}" 'none required'        "Branch deletion row must state its OWN evidence predicate: none required"
in_row    "${r_branch_deletion}" 'merged commit history' "Branch deletion recovery must be from the MERGED COMMIT HISTORY, not the deleted remote ref"
in_row    "${r_branch_deletion}" 'recoverable'          "Branch deletion row predicate must state the branch is recoverable (from merged history)"
# Defect-3 (finding 3): the two deletion paths differ — document and row-pin the
# distinction. merge-pr.sh cleanup warns and continues (exit 0); finish-issue.sh
# DELETE_BRANCH=1 exits nonzero on a local deletion failure.
in_row    "${r_branch_deletion}" 'merge-pr'             "Branch deletion row must name the merge-pr.sh warn-and-continue cleanup path"
in_row    "${r_branch_deletion}" 'warns and continues'  "Branch deletion merge-pr path must WARN AND CONTINUE (never fail the merge)"
in_row    "${r_branch_deletion}" 'finish-issue'         "Branch deletion row must name the finish-issue.sh path"
in_row    "${r_branch_deletion}" 'DELETE_BRANCH'        "Branch deletion row must name the DELETE_BRANCH=1 trigger"
in_row    "${r_branch_deletion}" 'exits nonzero'        "Branch deletion finish-issue path must EXIT NONZERO on a local deletion failure"
in_row    "${r_branch_deletion}" 'warn-only'            "Branch deletion row must classify the merge-pr cleanup coverage as warn-only"
in_row    "${r_branch_deletion}" 'decoupled'            "Branch deletion row must state its cleanup is decoupled from merge success"
in_row    "${r_branch_deletion}" 'soft'                "Branch deletion row must flag the merge-pr cleanup as deliberately soft"
# Finding 1: the recovery claim must DISTINGUISH content recovery on `main` from
# exact branch-history recovery. After a squash/rebase merge the exact per-commit
# history never lands on `main`, so once the remote ref is deleted and merge-pr
# force `git branch -D` drops the local ref, the EXACT branch history is NOT
# recoverable — only the merged CONTENT is. Contrast merge-pr force `-D` (drops
# regardless of merge status, risking unmerged history) vs finish-issue safe
# `-d` (refuses to delete unmerged history).
in_row    "${r_branch_deletion}" 'content recovery'    "Branch deletion row must distinguish CONTENT recovery on main (holds) from exact branch-history recovery"
in_row    "${r_branch_deletion}" 'exact branch-history' "Branch deletion row must state EXACT branch-history recovery is NOT guaranteed after squash/rebase + remote delete + local -D"
in_row    "${r_branch_deletion}" 'squash'              "Branch deletion row must state a squash/rebase merge drops the exact per-commit history from main"
in_row_cs "${r_branch_deletion}" 'git branch -D'       "Branch deletion row must name the merge-pr FORCE delete git branch -D (drops ref regardless of merge status)"
in_row_cs "${r_branch_deletion}" 'git branch -d'       "Branch deletion row must name the finish-issue SAFE delete git branch -d"
in_row    "${r_branch_deletion}" 'unmerged history'    "Branch deletion row must contrast force -D (risks losing unmerged history) vs safe -d (refuses it)"
in_row    "${r_branch_deletion}" 'refuses'             "Branch deletion row must state safe git branch -d REFUSES to drop a branch with unmerged history"

r_deploy="$(row 'Deploy')"
[ -n "${r_deploy}" ] || fail "could not extract the Deploy / Terraform apply inventory row"
in_row "${r_deploy}" 'future' "Deploy row must name the boundary as FUTURE work"

# ==============================================================================
# Verdict.
# ==============================================================================
if [ "${fails}" -ne 0 ]; then
  printf '\n%d boundary-inventory contract violation(s).\n' "${fails}" >&2
  exit 1
fi
printf 'boundary-inventory contract honored\n'
exit 0
