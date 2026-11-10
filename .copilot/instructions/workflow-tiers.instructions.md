---
description: 'Impact-based workflow classification; host lifecycle gates remain mandatory.'
applyTo: "**"
---

# Workflow Tier Classification

This file owns the classification rubric. The host repository owns the delivery
lifecycle and authorization rules; in this harness, follow
[harness.instructions.md](harness.instructions.md). Tiers vary planning depth and
review output, not mandatory gate eligibility.

## Workflow Tiers

Route clearly read-only work to Tier 0 and clearly low-risk corrections to
Tier 1. For other changes, investigate and plan proportionately before deciding
Tier 2 or Tier 3 from the planned impact; an initial Tier 2/3 guess is not required.
Known risks and authorization limits apply during investigation, not only after
classification. If a Tier 1 task reveals material risk, reassess before proceeding.

An explanation is Tier 0; a local spelling correction can be Tier 1. A one-line
change to an approval control is not Tier 1 merely because the edit is small.
If the spelling correction turns out to alter executable configuration,
reassess its effects before continuing. Use applicable host configuration or
deployment skills without treating the task name as its risk classification.

### Tier 0 — Direct answers

Questions, explanations, status checks and reading logs with no intended state
change. Respond directly without planning or issue ceremony. Terminal use alone
does not make work read-only: a destructive command is not Tier 0.

### Tier 1 — Fast path

Local, reversible corrections with understood behavior that preserve existing
contracts and operating boundaries, with no new material trust, data-loss or
external-side-effect risk. Use a brief approach and applicable targeted checks;
follow the host lifecycle for review and delivery.

### Tier 2 — Lightweight structured

Bounded behavioral development within the existing architecture, with known
affected consumers that can be updated and verified together, and no material
Tier 3 impact. Updating an internal parser and its repository-owned callers can
qualify even when their internal interface changes.

### Tier 3 — Consequential boundaries

Material changes to trust or security controls (including authentication,
authorization, data isolation and approval controls), data-loss exposure,
irreversible external effects, consequential breaking contracts for independent
consumers, or architectural transitions requiring coordinated system changes.
Use deeper planning and risk-relevant safeguards for the actual impact.

Using an existing security mechanism is not the same as changing its policy.
Changing an independently consumed contract is not the same as updating known
internal callers together. Describing a possible deployment in a document is
not itself a deployment; actual provisioning, activation or teardown must be
assessed for its effects and authorization.

File/module count, internal interface changes, phased implementation, unfamiliarity
and planning depth alone do not establish Tier 3. Honor a request for deeper
planning without automatically changing the risk classification. Uncertainty
directs investigation; consequences determine safeguards. Investigate credible
critical risk before treating a change as contained. An agent capability limit
is a separate blocker, not a higher task-risk tier.

## Conclude planning with the classification

Inspect enough relevant consumers, controls and effects to choose the smallest
correct approach. Planning may be a few sentences; do not require a separate
document or exhaustive investigation just to select a tier.

Before implementation, state the tier and its impact-based reason in the
existing progress or conversation, together with any missing preparation. For
example: "Tier 2: all affected consumers are internal and updated and verified
together; no trust boundary or independent contract changes."

If a provisional assessment changes, explain what evidence changed it. A
Tier 2-to-3 upgrade extends only the missing preparation before implementation.
A Tier 3-to-2 downgrade requires evidence ruling out the suspected Tier 3 impact;
reuse the existing plan and valid evidence. Unchanged classifications need no
duplicate plan or repeated justification. This concludes planning, not a new
gate or routine approval pause.

If credible critical risk remains unresolved, do not claim Tier 2 containment.
Investigate further or stop before the affected boundary when a safe approach
cannot be established. A higher tier does not resolve a capability limitation
or grant missing authorization. Reassess whenever implementation reveals a
material scope or risk change, before crossing the newly affected boundary.

## Delivery follows the host lifecycle

Choose the approach before decomposing features, following
[the breakdown flow](../../docs/HARNESS.md#the-breakdown-flow-plan--clarify--feature_list).
In this harness, every coding issue retains issue authority, isolated
worktree/preflight, TDD, criterion/sensor evidence, independent whole-diff review,
current-HEAD approval, final applicable validation, PR/green CI and authorized
merge/closeout. Contained low-risk work uses a short approach and `concise` review;
material risk or consequential unresolved contracts warrant fuller planning and
`full` review under [Risk-proportionate delivery](harness.instructions.md#risk-proportionate-delivery).
Review output depth does not reduce the finding pass or required verdicts.

For chat-driven coding in an issue-driven host, draft the issue and obtain
approval to create it unless that authority is already explicit. If declined,
do not implement inline. Tier 0 and explicitly waived personal scratchpad work
are exempt. An existing approved issue needs no repeat handshake.

Work autonomously within the authorized scope through implementation, verification
and the agreed delivery endpoint. Ask only when missing requirements,
consequential tradeoffs or authorization prevent safe progress. Classification
does not expand that authority or waive security, privacy, publication or merge
controls. Run applicable required checks; broaden or repeat only when changes,
failures or unresolved concerns justify it, then continue to completion.
