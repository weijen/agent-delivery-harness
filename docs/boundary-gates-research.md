# Hard Gates at Irreversible Boundaries: Evidence Predicates over `trace.jsonl`, Not Prompt Obligations

**Date:** 2026-07-22
**Scope:** the harness lifecycle's irreversible/expensive boundaries (PR create, PR merge, closeout
conclusion, worktree teardown, issue close, branch deletion, and the not-yet-existent deploy boundary), the
evidence each gate verifies in `trace.jsonl`, and where a machine-readable evidence contract would
consolidate today's hand-rolled checks.
**Questions asked:** (1) which boundaries are *irreversible or expensive*, and for each — what is the
motivating incident, the evidence predicate over `trace.jsonl`, and the current gate coverage/gap?
(2) can one machine-readable contract express those predicates and replace duplicated hand-rolled
checks at a net-negative line cost? (3) which obligations are deliberately left ungated, and why?
(4) against what snapshot was this written, and what must be revalidated after the open epic-#331
siblings merge?

> **This is a research issue.** The only artifacts it delivers are this report and its executable
> structural sensors. It *proposes* a contract and gate consolidation; it does **not** modify
> `docs/harness-contract.yml`, any lifecycle script, or any gate behavior. Those remain frozen and
> are changed only by a separate implementation issue.

---

## Executive summary

Process integrity in this harness does not come from asking the model to behave. It comes from
**deterministic gates that verify recorded evidence** before an irreversible or expensive action is
allowed to proceed. That evidence is, today, **plural** — not a single source: an authoritative,
re-queried GitHub record (`gh pr list --state merged` for the exact branch), the explicit
`ABANDONED=1` operator flag, and the append-only `trace.jsonl` span record. `trace.jsonl` is the
record source this issue *proposes* to make single; in the current closeout/teardown gate it is one
leg among these, and its `pr_merge` cross-check leg is **best-effort** — `finish__pr_merge_evidence_ok`
passes permissively when the trace file or `jq` is unavailable, so a missing trace cannot block.
Two anchor incidents frame the
inventory: **#316**, where the gate *caught* a model that narrated a "verification-only closeout"
with no PR and forced a real PR (#321); and **#328**, where a wrapper `gh pr merge` exited `0` while
the PR was still open, proving that a **wrapper exit code is not evidence** — only an authoritative,
re-queried `MERGED` state with a non-empty merge SHA is.

| Boundary | Irreversible action | Owner script | Gate today | Evidence over `trace.jsonl` |
| --- | --- | --- | --- | --- |
| **PR create** | `gh pr create` after rebase+push | `scripts/create-pr.sh` + `scripts/review-gate.sh` | **hard** | local approved-head marker == current HEAD is the **hard** predicate (patch-id carry across rebase); the matching `review_gate_approve` trace span is **advisory** (absent span NOTE-skipped, consistency warn-only by default) |
| **PR merge** | `gh pr merge` | `scripts/merge-pr.sh` | **hard, strong** | `pr_merge` span with `merge_state=MERGED` **and** non-empty `merge_sha`; CI checks green and non-empty first |
| **Closeout conclusion** | write-once terminal `Conclusion:` | `scripts/finish-lib.sh` | **hard** | first-write / idempotent same-value: the first terminal conclusion is written once, an identical re-write is idempotent, a *different* value refused; `merged` requires an authoritative merged-PR record. Gap: duplicate `Conclusion:` lines are not detected |
| **Worktree teardown** | `git worktree remove` | `scripts/finish-issue.sh` | **hard** (span leg **warn-only**) | before teardown: a **live** authoritative merged PR (`gh pr list --state merged`) exists for the branch, or `ABANDONED=1`; the `trace.jsonl` `pr_merge` span is an optional, permissive cross-check |
| **Issue close** | close the GitHub issue (`closed` state) — manual or PR keyword | *(external — GitHub)* | **none (unguarded)** | *(desired)* a recorded unique terminal `Conclusion: merged|abandoned` line — not merely the merged-PR/ABANDONED input — before the external CLOSED transition; duplicate-conclusion detection is an unmet gap |
| **Branch deletion** | `git push origin --delete` + local delete (two paths) | `scripts/merge-pr.sh` / `scripts/finish-issue.sh` | **warn-only, force `git branch -D`** (merge-pr) · **hard local stop, safe `git branch -d`** (finish-issue `DELETE_BRANCH=1`) | content recovery on `main` holds; exact branch-history recovery is NOT guaranteed after squash/rebase + remote delete + force `git branch -D` |
| **Deploy / Terraform apply** | *(none implemented)* | *(future)* | *(none — future work)* | *(future)* a provenance predicate must hold before the apply/release |

The consolidation opportunity, developed in the Contract Proposal section, spans **two distinct
kinds of duplication** — they must not be conflated. First, three near-identical review-gate
functions (`red_first_evidence_gate`, `review_reject_cap_gate`, `review_verdict_gate`) each
**re-shell out** to `scripts/check-trace-consistency.sh` and grep for a named `VIOLATION consistency:`
line — repeated external-checker invocations. Second, and by a *different* mechanism,
`finish__pr_merge_evidence_ok` does **not** re-shell that checker at all: it is **inline `jq`** inside
`scripts/finish-lib.sh` that re-reads the last `pr_merge` span and re-derives the
`merge_state=MERGED` + non-empty `merge_sha` predicate that `merge-pr.sh` §3b already computed —
duplicated **inline predicate logic**, not a checker re-shell. One declarative `boundary_gates:`
table consumed by a single `evidence_gate` helper expresses both once, at a net-negative line cost,
and closes the contract's own admitted blind spot: `failure_modes` is presence-based and cannot
detect a `hard`↔`warn` flip that preserves the message text.

---

## Boundary Inventory

Each row below is an **irreversible or expensive boundary**: an action the harness cannot cheaply
undo (a published PR, a merged commit, a written terminal conclusion, a removed worktree). For each
boundary the inventory names the irreversible action, the **motivating incident** that forced the
gate, the **evidence predicate over `trace.jsonl`** the gate verifies, and the current **coverage or
gap**.

**Thesis.** Process integrity comes from **deterministic gates verifying recorded evidence** — *not*
from **model compliance** with prose obligations, and *not* from trusting a wrapper's **exit code**.
The authoritative evidence today is **plural**, not a single source: an authoritative re-queried
GitHub record (`gh pr list --state merged` for the branch), the explicit `ABANDONED=1` operator flag,
and the append-only `trace.jsonl` span leg. `trace.jsonl` is the record source the issue *proposes*
to make single; the current closeout/teardown gate reads **live GitHub state** and `ABANDONED=1` as
its hard authority and treats the `trace.jsonl` `pr_merge` span only as a best-effort cross-check
(`finish__pr_merge_evidence_ok` returns OK when the trace file or `jq` is absent). The two anchor
incidents make the point in both directions: **#316** is the gate *catching* a false "verification-only closeout" (a model-compliance failure the
gate refused, forcing real PR #321); **#328** is a `gh pr merge` wrapper returning **exit code** `0`
while the PR was still open (a weak-evidence failure the gate now defeats by re-querying the
authoritative `MERGED` state). The lesson from both: verify recorded evidence, distrust narration and
exit statuses.

| Boundary | Irreversible action | Motivating incident | Evidence predicate over `trace.jsonl` | Current gate coverage / gap |
| --- | --- | --- | --- | --- |
| **PR create** | `gh pr create` after rebase→push (`scripts/create-pr.sh`) | **#299** — the irreversibility-based pre-PR sensor list (prior art) | the **local approved-head marker** (`.copilot-tracking/review-gate/approved-head` line 1) equals the current HEAD — this **marker == HEAD** identity is the **hard** predicate (or a patch-id-carried approval via `harness.review_gate_carry`, #310); the matching `review_gate_approve` trace span (`harness.review_gate_sha`) is only an **advisory** cross-check; every `passes:true` feature carries its teeth-proof, `feature_start`, and `review_verdict` spans | **hard** via `scripts/review-gate.sh check` (marker line 1 != HEAD ⇒ exit 1) plus the `create-pr.sh` stale-approval carry (patch-id identity, #310). **Trace gap (advisory):** the matching `review_gate_approve` span is optional — an **absent** approval span is NOTE-skipped (`review_sha_mismatch check skipped (no review_gate_approve span in trace)`) and trace consistency is **warn-only** by default unless `REQUIRE_TRACE_CONSISTENCY=1`, so the local marker is the hard authority and the trace evidence is advisory. **Gap:** three near-identical gate functions — `red_first_evidence_gate`, `review_reject_cap_gate`, `review_verdict_gate` — each re-shell-out to `check-trace-consistency.sh` and grep a named `VIOLATION consistency:` line. |
| **PR merge** | `gh pr merge` (`scripts/merge-pr.sh`) | **#328** — `gh pr merge` exited `0` while the PR was still open, so the wrapper exit code lied | a `pr_merge` lifecycle span with `harness.outcome=pass` **must** carry `harness.merge_state=MERGED` **and** a non-empty `harness.merge_sha`; CI checks must have concluded green **and** be non-empty before the merge | **hard, strong.** `merge-pr.sh` §2 gates on green + non-empty `gh pr checks`; §3b re-queries `gh pr view --json state,mergeCommit` and stamps `merge_state`/`merge_sha` only when GitHub itself confirms `MERGED`; `finish__pr_merge_evidence_ok` cross-checks the span at closeout. The live `merge-pr.sh` re-query is the hard authority; the closeout span cross-check is a **best-effort** leg (it passes permissively when the trace file or `jq` is absent). |
| **Closeout conclusion** | write-once terminal `Conclusion:` in `progress.md` (`scripts/finish-lib.sh`) | **#323** — write-once terminal conclusion | **first-write / idempotent same-value** semantics: the first `Conclusion:` line is written once, an identical re-write is idempotent, and a *different* later value is refused (`return 2`); a `merged` conclusion additionally requires an authoritative merged-PR record for the branch | **hard** for first-write and same-value idempotence. `finish__atomic_conclusion` reads only the **first** matching `Conclusion:` line and refuses a different value; `finish_progress_finalize` requires an authoritative merged PR (or `ABANDONED=1`) before a `merged` conclusion. **Gap:** because it reads only the first match it does **not** detect a **duplicate** `Conclusion:` line — a pre-existing second conclusion (same *or* different value) is neither rejected nor reconciled, so "exactly once" is not enforced against duplicate lines. |
| **Worktree teardown** | `git worktree remove` (`scripts/finish-issue.sh`) | **#316 / #321** — a model narrated a "verification-only closeout" with **no PR**; the gate rejected it and forced reopen + real PR #321 | before teardown: an authoritative **merged PR** for the branch, queried **live via `gh pr list --state merged`** (**not** read from `trace.jsonl`), *or* the explicit `ABANDONED=1` flag; the `trace.jsonl` `pr_merge` span is only an optional cross-check | teardown is hard-blocked by `finish_progress_finalize` (no live merged PR and no `ABANDONED=1` ⇒ refuse). **Gap:** the `trace.jsonl` `pr_merge` cross-check (`finish__pr_merge_evidence_ok`) is **permissive** — it returns OK when the trace file or `jq` is unavailable — and the span-presence leg (`finish_trace_gate`) is **warn-only** unless `REQUIRE_TRACE_CONSISTENCY=1`, so trace-level honesty is advisory while the live merged-PR fact is hard. |
| **Issue close** | closing the GitHub issue — an irreversible external **GitHub issue state** transition to `closed`, reached **manually** or via a PR closing keyword | **#316** — the issue was **manually closed without a PR**, then reopened after `finish` **rejected the closeout** | *(desired)* a **recorded unique terminal `Conclusion: merged|abandoned`** line in `progress.md` — the required **terminal closeout evidence**, **not merely** the merged-PR/`ABANDONED=1` *input* — must exist before the external GitHub issue state transitions to **CLOSED**. The predicate keys on the **recorded conclusion**, written only after an authoritative **merged PR** (or a **governed `ABANDONED=1` abandonment**); the harness writes only `merged`/`abandoned` conclusions, never a `closed` one, so it gates the external **CLOSED** transition on that recorded terminal conclusion, not a nonexistent closed conclusion. **The uniqueness is itself unmet:** `finish__atomic_conclusion` reads only the **first** `Conclusion:` line, so a **duplicate** terminal conclusion is undetected — a predicate keyed on a *unique* terminal conclusion **inherits** the duplicate-conclusion gap from the Closeout row | **No direct harness issue-close gate.** `finish` hard-blocks worktree *teardown* without a merged PR (or `ABANDONED=1`), but it **cannot prevent** a **manual or GitHub-keyword** issue closure — the `closed` state lives outside the harness, so the boundary is unguarded. |
| **Branch deletion** | remote/local **branch deletion** — `git push origin --delete` + local branch delete, along **two paths** (`merge-pr.sh` post-merge cleanup / `finish-issue.sh` with `DELETE_BRANCH=1`) | **#167** — the worktree-cleanup incident | none required for the merged **content**: **content recovery on `main`** holds because the merged (often **squashed/rebased**) content already lives on `main` as the **merged commit history**, so the content is **recoverable** on `main` without the deleted remote ref. But **exact branch-history recovery** is **NOT** guaranteed — after a **squash** or rebase merge the original per-commit SHAs never land on `main`, and once the remote ref is deleted and merge-pr force-deletes the local ref (`git branch -D`) the exact branch history is unrecoverable (only a local reflog, if present, retains it). Distinguish **content recovery on `main`** (holds) from **exact branch-history recovery** (lost after squash/rebase + remote delete + local `-D`) | **Two paths differ.** (a) `merge-pr.sh` post-merge cleanup deletes the remote (`git push origin --delete`) then **force**-deletes the local branch (`git branch -D`), which **drops the ref regardless of merge status** and would silently discard **unmerged history**; each step **warns and continues**, never failing the merge — **warn-only**, **soft**, **decoupled** from merge success. (b) `finish-issue.sh` with `DELETE_BRANCH=1` uses a **safe** local delete (`git branch -d`) that **refuses** to drop a branch carrying **unmerged history** and **exits nonzero** on a local deletion failure (`exit 1`) — a hard local stop, not warn-only. The force `git branch -D` path is the deletion **risk**; the safe `git branch -d` path protects unmerged history. |
| **Deploy / Terraform apply** | *(none implemented today)* | — | *(future)* a provenance predicate must hold before the apply/release | **No such boundary exists in the current lifecycle** — deliberately ungated now and named here as the **next boundary to add** (future work) when a deploy/release lifecycle lands. |

**How to read "coverage / gap".** A boundary marked **hard** refuses the irreversible action on
missing or contradictory evidence and exits non-zero. A leg marked **warn-only** prints an advisory
note and continues (exit `0`) unless an explicit escalation flag (e.g. `REQUIRE_TRACE_CONSISTENCY=1`)
promotes it. The distinction is the same `kind: hard|warn` axis the harness contract already
classifies — which is exactly why the Contract Proposal section argues these predicates belong in one
declarative table rather than scattered across hand-rolled shell functions.
