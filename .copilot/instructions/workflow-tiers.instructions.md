---
description: 'Personal workflow doctrine — Workflow Tiers and the slim two-subagent Tier 3 pipeline. Cross-project; applies everywhere.'
applyTo: "**"
---

# Personal Workflow Doctrine

You are the conductor. This file is your operating doctrine across **every** project — repo conventions still
override it. When the host repo has its own harness instructions, follow the stricter local rule. This is the default
workflow when the host project doesn't specify one.

## Workflow Tiers

Every coding task is classified into one of four tiers before work begins.

| Tier | When to use | Subagents | Plan file | Tests | Commit-strategy ask |
| ---- | ----------- | --------- | --------- | ----- | ------------------- |
| 0    | Questions, explanations, shell-only / read-only ops | None | No | None | No |
| 1    | 1–3 file low-risk edits, no API/infra/security impact | Main-agent self-check; no subagent unless user asks or risk surfaces | No | Targeted only | No (commit on request) |
| 2    | Multi-file change with behavior change needing tests; contained scope | Optional single `code-review-subagent` pass when risk warrants it or the user asks | Only if user asks or work spans sessions | Targeted first; full suite at end / when risk justifies | No (commit on request) |
| 3    | Auth, security, infra, teardown, cross-module refactor (5+ files), or user requests phased/planned work | Full pipeline: plan in `.copilot-tracking/plans/` → single-agent implementation (#352) → `code-review-subagent` | Yes, in `.copilot-tracking/plans/` (host repo should gitignore this) | Full suite at milestones and completion | Yes, ask at the start |

### Tier 0 — Direct answers

Questions, explanations, branch switches, status checks, reading logs, simple terminal ops. Respond directly. No
planning, no plan files, no commit-strategy questions.

### Tier 1 — Fast path

All of: 1–3 files, no public-API/architecture/auth/security/infra/destructive scope, no cross-module contract change,
user didn't ask for formal review.

State a brief approach, edit, run targeted tests (`<project test command> path::test_name`), self-check the diff. No
plan file, no review subagent unless risk surfaces or the user asks. Commit only on request.

### Tier 2 — Lightweight structured

Multiple related files, behavior change needing tests, some uncertainty but no broad architectural risk.

Inline short plan (in chat, not a file). Targeted TDD for behavior changes. **Optional** one review pass after
implementation when risk warrants or the user asks — use `code-review-subagent` in `concise` mode. Targeted tests
first; full suite at end. No plan file unless user asks or work spans sessions. Commit only on request.

### Tier 3 — Full orchestrated workflow

Any of: auth, security, telemetry, infra, deployment, teardown; cross-module architecture changes; new tools/plugins
with code + config; large refactors (5+ files, behavior across modules); user explicitly asks for plan / phased work /
strict TDD / subagent review; work spans multiple phases or sessions.

Uses `code-review-subagent` for the independent review (#352 retired the planning/generator
subagents — plan directly in `.copilot-tracking/plans/`); otherwise the main
agent implements directly. In a contract-v2 issue harness, one delivering agent follows
`gate_start`, `gate_sensors`, `gate_review`, and `gate_merge_closeout`; local harness rules replace the generic
approval pauses below.

## Shared Principles

- **YAGNI** — Only build what was asked for. No speculative features, no "while we're here" improvements.
- **TDD** — Write tests first. Run them to verify they fail for the right reason. Then write the minimal code to make
  them pass.
- **DRY** — But not at the cost of tight coupling. Three similar lines beat a premature abstraction.
- **Bite-sized phases** — One concern per phase. If a phase feels too big, split it.
- **Project conventions first** — Follow the host repo's formatting, naming, and test patterns. Verify with the
  project's lint/format commands for any code change.

## Routing

When a request arrives, classify the task type and respond accordingly.

- **Tier 0 (questions, explanations, branch switches, status checks, reading logs)** — respond directly with no
  orchestration. No issue requirement, no subagent.
- **Configuration-only edits** in a repo with explicit configure skills — use the host repo's configure skill if
  present; otherwise treat as Tier 1 or Tier 2 by scope.
- **Setup, teardown, deployment** in a repo with explicit setup/teardown/deploy skills — use the host repo's skill if
  present; otherwise classify by scope.
- **Coding tasks (Tier 1+)** — classify by the tier rubric above.

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

The conductor invokes subagents through the `runSubagent` tool. **To invoke a subagent, read the agent's `.agent.md`
file and pass its full content plus relevant work context as the subagent prompt.**

Personal subagent locations:

- `.copilot/agents/code-review-subagent.agent.md`

### 1. Start

Acknowledge the task. Ask commit preference:
"Should I auto-commit after the implementation passes review, or commit manually? (auto/manual)"

### 2. Plan

Write the plan yourself in `.copilot-tracking/plans/` (deep detail). Include the user's request, conversation context,
and any relevant host-repo conventions you've already gathered.

### 3. Plan approval — MANDATORY PAUSE

Summarise the plan (approaches considered, number of phases, key decisions, open questions). **Wait for user
approval.** Do not proceed until approved.

### 4. Implement (phase by phase)

For each phase in the approved plan:

a. **Implement** — follow the host repo's implementation path (#352: single agent) for
  the selected feature's complete RED, minimal implementation, GREEN, teeth-proof, and pass-state cycle; otherwise
  the conductor implements directly.
   - For behavior changes, follow strict TDD: failing test → verify right failure → minimal implementation → passing test.
   - Apply style fixes scoped to touched files using the project's lint/format commands.
   - Run targeted tests during the phase; run the full suite at milestones and at the end.

b. **Verify** — run the selected feature's declared sensors and mark `passes:true` only after checks and
  product-quality blocking gates pass.

c. **Self-check** — before declaring the phase done, scan the diff: lint clean, tests pass, no debug leftovers, no
  unrelated changes.

d. **Commit** — if user chose auto-commit, write a conventional-commit message (`type(scope): summary` ≤ 50 chars,
   body bullets, no internal-workflow references). **Use the user's existing signing setup** — never disable signing
   to avoid a passphrase prompt. If manual, stage the changes and present the commit message; let the user commit.

### 5. Review — MANDATORY PAUSE before close

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

- Every 3 phases, or at the end: pause, summarise progress, wait for user confirmation before continuing.

For blocker, retry, and review-feedback handling, see **When to Stop and Ask** and **Important Rules** below — those
rules are stated once there.

## Optional: host-repo issue-lifecycle commands

When the host repo provides its own issue-lifecycle commands (preflight, issue init, finish/close), prefer them over
this file's defaults as the shell layer around the pipeline above. This repo's own harness is script-based
(`scripts/start-issue.sh`, `scripts/finish-issue.sh`, `.copilot-tracking/issues/`) — there is no Taskfile — so treat
any `task …` invocation as illustrative, not a command to hunt for.

## When to Stop and Ask

Stop and ask the user when:

- A subagent hits a blocker (missing dep, unclear instruction, repeated test failure).
- The plan has critical gaps that prevent starting a phase.
- A subagent returns an unclear or unexpected result.
- Verification fails repeatedly (same test failing after 2 fix attempts).
- You're unsure which phase to execute next.

Do **not**:

- Retry the same failing operation more than twice.
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

- For Tier 3 work, you are the conductor. You delegate planning and review to subagents and implement directly.
- For Tier 1 and Tier 2 work, you may implement directly with at most one optional review pass at the end.
- Never force-push or amend commits that have already been pushed.
- Never proceed past a mandatory pause (plan approval, final review, every-3-phase milestone) without user
  confirmation.
- When relaying review feedback to revision, include the full feedback — don't summarise or soften it.
