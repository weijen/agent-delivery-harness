---
agent: agent
description: 'Deliver one issue feature; complete review and closeout when it is the last feature.'
---

# Session Ritual

Work on issue **${input:issue:GitHub issue number}** using the project's `AGENTS.md`
and [canonical issue lifecycle](../instructions/harness.instructions.md).

Start or resume its isolated worktree, read the live issue and local state, then
deliver the highest-priority eligible `passes:false` feature. Work on one item
at a time using TDD and its scoped completion sensors; commit, push and update
progress before stopping.

If unfinished features remain, stop after this feature. If all features pass
(including when they already pass on entry), continue through the lifecycle's
independent review, required repairs, final applicable validation, PR, green CI,
merge and closeout. Repair items are also delivered one at a time. Use the existing
scripts and authority boundaries; stop on unresolved blockers rather than bypassing gates.

Report the feature/result, checks run and outcomes, commit SHA, and next feature or
blocker. At issue completion, include the PR and verified merge/closeout state.
