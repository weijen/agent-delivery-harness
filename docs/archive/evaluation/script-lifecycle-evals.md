# Script Lifecycle Evals

## Purpose

Script lifecycle evals protect the deterministic core of the harness. These
should be implemented before probabilistic skill or subagent evals because they
are cheap, objective, and directly tied to the existing harness contract. They
are the L0 layer: the most attributable and the cheapest to run on every commit.

## Targets

- `scripts/init.sh`
- `scripts/issue-lib.sh`
- `scripts/start-issue.sh`
- `scripts/check-feature-list.sh`
- `scripts/review-gate.sh`
- `scripts/create-pr.sh`
- `scripts/finish-issue.sh`

## Required Eval Themes

### Lifecycle Order

Verify that the lifecycle still follows the contract:

1. Preflight.
2. Issue lookup.
3. Branch and worktree creation.
4. Local tracking scaffold.
5. Feature-list validation.
6. Review approval for current HEAD.
7. PR creation.
8. Merge confirmation.
9. Worktree cleanup.

Presence checks are not enough. At least one fixture should execute the path in
a temporary repository and assert observable state transitions.

### Hard vs Warn Semantics

Each declared hard failure and warning-only path should have a fixture:

- Missing `git`: hard.
- Missing `gh`: hard.
- GitHub auth failure: hard.
- Missing optional language tool: warning or skip.
- Missing `jq` in feature-list validation: warning or skip where currently
  intended.
- Incomplete feature list: warning by default, hard under
  `REQUIRE_FEATURES_COMPLETE=1`.
- Dirty worktree closeout: hard unless `FORCE=1`.
- Stale review approval: hard.

### Linked Worktree Safety

Verify that scripts which must run from the main checkout refuse linked worktree
invocation, and scripts that operate inside issue worktrees resolve paths
correctly.

### Fake CLI Fixtures

Script evals should use fake commands on `PATH` for `gh`, `az`, `uv`, `go`,
`pnpm`, `terraform`, `mvn`, `gradle`, and `bundle` where possible. Tests should
not depend on the developer's global machine state.

## Dataset Shape

Shell lifecycle evals can be ordinary shell tests. Each scenario should declare:

- Fixture name.
- Script under test.
- Environment variables.
- Fake commands on `PATH`.
- Expected exit code.
- Expected stdout or stderr fragments.
- Expected file/git state.

These cases are deterministic, so they need none of the statistical machinery in
[statistical-methodology.md](statistical-methodology.md); a single run is
authoritative.

## Public Dataset Seeds

No public benchmark directly covers this harness's shell lifecycle contract,
because the required behaviors are repo-specific: branch/worktree creation,
Action Log scaffolding, feature-list validation, review-gate freshness, and
finish cleanup. Build these as local fixtures.

Public benchmarks are still useful as design references:

- [Terminal-Bench](https://www.tbench.ai/) shows how to package terminal tasks
  with executable verification and isolated environments.
- [SWE-bench](https://github.com/SWE-bench/SWE-bench) shows how to run
  containerized software-engineering evaluation reproducibly, but its issue
  tasks do not exercise this harness's script lifecycle.

Do not import external tasks as L0 gates unless they are rewritten into small,
deterministic fixtures for the scripts listed above.

## Initial Issues To Create Later

1. Add executable lifecycle-order fixture for the harness contract.
2. Add hard/warn semantic fixtures for `check-feature-list.sh` and
   `finish-issue.sh`.
3. Add fake CLI harness for `init.sh` language-surface detection.
4. Add review-gate HEAD-bound regression fixture.
5. Add Bash instruction coverage for script and test authors.

## Acceptance Criteria

- Contract tests fail when lifecycle order is broken.
- Tests prove hard/warn semantics with exit codes, not only text presence.
- Tests run in temporary repositories and clean up after themselves.
