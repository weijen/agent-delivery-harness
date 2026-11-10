---
agent: agent
description: 'Deliver an authorized issue sequentially through independent review and verified closeout.'
---

# Session Ritual

Work on issue **${input:issue:GitHub issue number}** using the project's `AGENTS.md`
and [canonical issue lifecycle](../instructions/harness.instructions.md).

Start or resume its isolated worktree and read the live issue and local state.
Deliver the highest-priority eligible `passes:false` feature using applicable
TDD and scoped completion sensors. Verify, commit, push and update progress,
then immediately select the next required feature. One feature at a time means
sequential execution, not one feature per session; request no routine permission
between features.

When all features pass (including on entry), continue through independent review,
required repairs, candidate-bound approval, final applicable validation, PR
publication, green CI, merge and verified closeout. Repair items are sequential;
diagnose and repair recoverable failures without automatic handback.

Preserve this objective across compaction/resumption, subject to the latest
explicit user instruction, including planning-only, review-only, one-feature-only,
pause or cancellation requests. Respect genuine safety, authorization or
escalation blocks. Pending CI calls for waiting; recoverable failures call for
repair within existing limits. Use the existing scripts and gates; never
fabricate completion, bypass safeguards or expand into unrelated issues.

Report delivered results, checks and outcomes, commit SHA, PR and verified
merge/closeout state. At a narrower endpoint or genuine block, report the actual
state and remaining work without claiming the issue is complete.
