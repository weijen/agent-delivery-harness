# AGENTS.md — Map for AI agents working in this harness repo

This repository is a reusable, language-agnostic harness for issue-driven delivery:
preflight, isolated worktrees, local progress, quality gates, independent review and
PR closeout. Product requirements and provider conventions belong to the adopting
project, not the harness.

## Post-compaction re-anchor

After any context compaction, re-read this block before continuing.
- Emit `deviation` when it happens and `review_verdict` at review handback.
- On a `review_verdict` fail, `log-handback.sh` requires `TRACE_FAILURE_CLASS`, `TRACE_FINDING_FINGERPRINT`, `TRACE_FINDING_BASELINE_STATE`, and `TRACE_ACTIONABLE` (true demands a reproduction or proposed fix); omit optional attributes rather than guessing.
- Before authenticated GitHub operations, call `harness_identity_activate`; never run `gh auth switch`.

## Choose the task path

- **Questions and read-only reviews:** answer directly. Do not start an issue,
  worktree, implementation, review pipeline or publication merely to answer.
- **Issue delivery:** read the [canonical lifecycle](.copilot/instructions/harness.instructions.md)
  before acting. It owns planning, feature selection, sensors, review, publication
  and closeout; generic workflow defaults do not replace its gates.
- **Other authorised work:** follow the project's conventions and use the
  [workflow routing guide](.copilot/instructions/workflow-tiers.instructions.md)
  when the task does not enter issue delivery.

## Safety and delivery invariants

- Never commit customer/confidential material, raw media, screenshots, decks,
  exports, secrets or local environment files. Use explicitly sanitised fixtures.
- Privileged cloud/provider operations go through approved project wrappers and
  environment configuration, never hard-coded credentials or raw privileged calls
  from a worktree.
- GitHub issue descriptions **and comments** are the requirements authority:
  `gh issue view <N> --comments`. Local tracking is progress, not an issue draft.
- Deliver one criterion-sized `feature_list` item at a time with TDD and scoped
  sensors. `passes:true` requires regression evidence and real runtime evidence
  when a boundary exists. Commit and push each completed feature, update progress,
  and leave a clean state.
- Keep independent review (including required repair review), current-HEAD
  approval, final applicable validation and green CI before merge. Use the
  lifecycle scripts; finish authorised merge/closeout rather than leaving manual
  work for the human.
- Keep verification proportionate: preserve necessary negative, safety and runtime
  protection without duplicate cases or repeated gates. Do not add prose-pinning tests.

## Start or resume issue work

From the main checkout: `./scripts/start-issue.sh <N>`, then enter its printed
worktree path. To resume, enter the existing worktree and run `./scripts/init.sh`.
For cloud/infrastructure/deployment work, prefix preflight/startup with `REQUIRE_AZ=1`.
Keep shell entrypoints under `scripts/`, not at the repository root.

Required validation shares a hard 900-second test budget. Compose checks with
`scripts/validation/validate.sh`; do not reset the budget or remove coverage to fit
it. See the [runtime contract](docs/HARNESS.md#shared-test-execution-budget).

## Commit message convention (Conventional Commits)

Use `type(scope): subject`, with issue scope when applicable, e.g.
`docs(#568): simplify prompt routing`. Preserve the existing signing setup.
`fix` and `feat` drive automatic releases; `docs`, `test`, `refactor`, `chore`,
`ci`, `build` and `style` do not. Breaking-change and 1.0.0 policy live in
[the releasing guide](docs/RELEASING.md).

## Sources of truth

| Need | Read |
| --- | --- |
| Full issue lifecycle, sensors, review and escalation | [.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md) |
| Human lifecycle overview and installation | [docs/HARNESS.md](docs/HARNESS.md), [docs/getting-started.md](docs/getting-started.md) |
| Host discovery and prompt invocation | [docs/github-copilot.md](docs/github-copilot.md) |
| Issue state | `.copilot-tracking/issues/issue-NN/feature_list.json`, `progress.md`, optional `plan.md` |
| Language profiles and generation | [profiles/README.md](profiles/README.md), [docs/multi-language-profiles.md](docs/multi-language-profiles.md), `scripts/scaffold-language.sh` |
| Applicable code conventions | `.copilot/instructions/<language>.instructions.md`; [Bash](.copilot/instructions/bash.instructions.md), [TDD](.copilot/instructions/tdd.instructions.md) |
| Frozen lifecycle contract | [docs/harness-contract.yml](docs/harness-contract.yml), `tests/scripts/lifecycle/test_harness_contract.sh` |
| Traces and retired capture history | [docs/observability-and-trace-schema.md](docs/observability-and-trace-schema.md) |
| Maintainer evaluation tooling | [docs/eval-tooling.md](docs/eval-tooling.md) |

## Skills and independent review

Read the relevant `.copilot/skills/<name>/SKILL.md` or
`.copilot/agents/<name>.agent.md` before use.

| Asset | When |
| --- | --- |
| `code-review-subagent` and `code-review` | At issue completion, over the whole branch diff; repair review is scoped to fixes |
| `public-exposure-audit` | Blocking exposure check in the independent review/pre-PR gate |
| `security-audit` | Risk-triggered under [Review acceptance policy](.copilot/instructions/harness.instructions.md#review-acceptance-policy), including approval controls and CI/workflows |
| `create-pr` | PR authoring through `scripts/create-pr.sh` |
| `find-brute-force`, `find-duplicates`, `find-over-design`, `dead-code-detection`, `sync-docs` | Owner-requested maintenance, not automatic per-PR protocols |

The reviewer may add the smallest dedicated test/fixture/validation asset needed
to expose a missing failure mode. Production remains read-only for the reviewer;
defects return to the delivering agent. The canonical lifecycle owns review
requirements and verdict recording.
