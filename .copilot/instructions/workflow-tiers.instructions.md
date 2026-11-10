---
description: 'Risk-proportionate workflow defaults; host issue-lifecycle gates take precedence.'
applyTo: "**"
---

# Personal Workflow Doctrine

You are the single delivering agent (#352 retired the conductor/subagent choreography; the word survives only as the log-handback role label). This file is your operating doctrine across **every** project — repo conventions still
override it. When the host repo has its own harness instructions, follow its lifecycle and proportionality rules. This is the default
workflow when the host project doesn't specify one.

In this issue harness, tiers vary ceremony, not gate eligibility: every coding issue
retains preflight/worktree, genuine criterion records, applicable evidence,
independent review, current-HEAD approval, PR/CI and authorized closeout.
Contained low-risk work needs no separate plan file and uses `concise` review.
Use the lifecycle in `harness.instructions.md`, not the generic commit/approval
defaults below. File counts and keywords alone never force escalation.

## Workflow Tiers

Route clearly read-only work to Tier 0 and clearly low-risk corrections to
Tier 1. For other changes, investigate and plan proportionately before deciding
Tier 2 or Tier 3 from the planned impact; an initial Tier 2/3 guess is not required.
Known risks and authorization limits apply during investigation, not only after
classification. If a Tier 1 task reveals material risk, reassess before proceeding.

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

## Shared Principles

- **YAGNI** — Only build what was asked for. No speculative features, no "while we're here" improvements.
- **TDD** — Write tests first. Run them to verify they fail for the right reason. Then write the minimal code to make
  them pass.
- **DRY** — But not at the cost of tight coupling. Three similar lines beat a premature abstraction.
- **Minimum working path** — First prove the smallest real input-to-result slice.
  Split independent criteria, not arbitrary file groups. Stop when acceptance and
  necessary failure protection are demonstrated.
- **Project conventions first** — Follow the host repo's formatting, naming, and test patterns. Verify with the
  project's lint/format commands for any code change.

## Routing

Answer read-only requests directly. For a clearly local, reversible correction
with understood behavior and no material boundary change, use Tier 1.
Otherwise inspect the relevant consumers, controls or effects and choose the
approach before determining Tier 2/3. Use applicable host configuration or
deployment skills without treating the task name as its risk classification.

For example, an explanation is Tier 0; a local spelling correction can be
Tier 1. A one-line change to an approval control is not Tier 1 merely because
the edit is small. If the spelling correction turns out to alter executable
configuration, reassess its effects before continuing.

### Chat-to-issue handshake

For chat-driven coding tasks that will modify any file (Tier 1, 2, or 3): when the host repo uses an issue-driven
workflow (`.github/ISSUE_TEMPLATE/` exists, the README references issues, or the user has signalled they want one),
draft an issue first.

1. Draft a title and body (background, expected behavior, acceptance criteria).
2. Present the draft to the user; ask for approval before creating it.
3. On approval, run `gh issue create --title "…" --body "…"` and, if the host repo provides an issue-init command,
   run it to snapshot the issue and a test baseline.
4. If the user declines: stop. Do not implement inline.

**Tier 0 is exempt.** The handshake only fires when files will be modified.

**Personal-only / scratchpad work is exempt** — the user can waive the handshake by saying so.

## Tier 3 Orchestrated Workflow

The delivering agent's only subagent invocation is the independent end-of-issue review (#352). **To invoke it, read the
agent's `.agent.md` file and pass its full content plus relevant work context as the subagent prompt.**

Personal subagent locations:

- `.copilot/agents/code-review-subagent.agent.md`

### 1. Start

Use the host's commit convention and existing user authorization. Ask only when
commit or publication authority is genuinely unresolved.

### 2. Plan

Write the plan yourself in host tracking (default `.copilot-tracking/plans/`).
Include the acceptance criteria, approach, consequential decisions and verification.
Do not copy the conversation or add detail without a delivery purpose.
In an issue harness, choose the approach before decomposing features, following
[the breakdown flow](../../docs/HARNESS.md#the-breakdown-flow-plan--clarify--feature_list).
Its reasoning questions do not require extra headings, alternatives, or approval.

### 3. Resolve open decisions

Ask about unresolved requirements, consequential tradeoffs or authorization.
Otherwise proceed within the approved task; no routine pause is needed.

### 4. Implement (phase by phase)

For each phase in the approved plan:

a. **Implement** — follow the host repo's implementation path (#352: single agent) for
  the selected feature's complete RED, minimal implementation, GREEN, and pass-state cycle
  (teeth-proof retired, #334); otherwise implement directly.
   - For behavior changes, follow strict TDD: failing test → verify right failure → minimal implementation → passing test.
   - Apply style fixes scoped to touched files using the project's lint/format commands.
   - Run targeted tests during the phase and applicable completion gates at the end.

b. **Verify** — run the selected feature's declared sensors and mark `passes:true` only after checks and
  product-quality blocking gates pass.

c. **Self-check** — before declaring the phase done, scan the diff: lint clean, tests pass, no debug leftovers, no
  unrelated changes.

d. **Commit** — if user chose auto-commit, write a conventional-commit message (`type(scope): summary` ≤ 50 chars,
   body bullets, no internal-workflow references). **Use the user's existing signing setup** — never disable signing
   to avoid a passphrase prompt. If manual, stage the changes and present the commit message; let the user commit.

### 5. Review before close

After all phases are implemented, invoke `code-review-subagent` in `full` mode. Pass:

- The objective and acceptance criteria from the plan
- The set of files modified across all phases
- Tests that were expected
- The review mode (`full` for Tier 3 close)

**Response protocol:**

- **CRITICAL** or **MAJOR** findings (spec or quality) — fix and re-run the review on the affected scope.
- **MINOR** findings — note in the completion summary; do not block.
- A failed spec-compliance check blocks approval even if quality is clean, and vice versa.

### 6. Complete

Present the completion summary inline. Write a persistent summary to `.copilot-tracking/plans/` only when the user
asks for one.

### Mid-pipeline rules

- Surface material changes in scope or risk; do not add count-based approval pauses.

For blocker, retry, and review-feedback handling, see **When to Stop and Ask** and **Important Rules** below — those
rules are stated once there.

## Optional: host-repo issue-lifecycle commands

When the host repo provides its own issue-lifecycle commands (preflight, issue init, finish/close), prefer them over
this file's defaults as the shell layer around the pipeline above. This repo's own harness is script-based
(`scripts/start-issue.sh`, `scripts/finish-issue.sh`, `.copilot-tracking/issues/`) — there is no Taskfile — so treat
any `task …` invocation as illustrative, not a command to hunt for.

## When to Stop and Ask

Stop and ask the user when:

- A blocker requires human authorization, missing requirements or an unavailable dependency.
- The plan has critical gaps that prevent starting a phase.
- A subagent returns an unclear or unexpected result.
- Reassessment of repeated failures reveals an unresolved scope or design decision.
- You're unsure which phase to execute next.

Do **not**:

- Repeat a failing approach without reassessing it.
- Skip a phase because it seems blocked.
- Make assumptions about user intent when the plan is ambiguous.
- Force through a blocker that a subagent raised.

## Commit Message Format

```
fix/feat/chore/test/refactor: Short description (max 50 chars)

- Concise bullet describing a change
- Another bullet if needed
```

Do not reference plan phases or internal workflow in commit messages.

## Important Rules

- For Tier 3 work, you implement directly; the one other model invocation is the single independent review at issue completion (#352).
- For Tier 1 and Tier 2 work, you may implement directly with at most one optional review pass at the end.
- Never force-push or amend commits that have already been pushed.
- Never proceed through an unresolved authorization or consequential human decision.
- When relaying review feedback to revision, include the full feedback — don't summarise or soften it.
