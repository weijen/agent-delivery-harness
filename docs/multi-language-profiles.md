# Multi-Language Harness Profiles Spec

## Purpose

The harness should support Python, Go, Node.js, Java, and Ruby without turning
`scripts/init.sh`, Copilot instructions, or agent guidance into copy-pasted
language branches. Language support must be added through small, explicit
profiles while preserving the existing issue-driven harness lifecycle.

The most important constraint is backwards compatibility: profile work must not
silently change how the current harness starts issues, creates worktrees,
scaffolds local tracking state, validates feature lists, enforces review gates,
opens PRs, or finishes issues.

## Non-Regression Contract First

Before any profile generator or language scaffold is implemented, the current
harness behavior must be captured as a versioned contract and validated by tests.
This contract is the baseline that future refactors compare against.

### Harness Contract Manifest

Add a committed machine-readable manifest, for example
`docs/harness-contract.yml`, that describes the current required lifecycle and
script boundaries. The manifest is not a generated diagram; it is the explicit
contract that says which actions the harness must continue to perform.

The manifest should cover:

- Required entrypoints: `scripts/init.sh`, `scripts/start-issue.sh`,
  `scripts/check-feature-list.sh`, `scripts/review-gate.sh`,
  `scripts/create-pr.sh`, and `scripts/finish-issue.sh`.
- Lifecycle order: preflight, issue lookup, branch/worktree creation, local
  tracking scaffold, feature-list validation, review approval, PR creation, PR
  merge, closeout, and worktree cleanup.
- Required inputs and environment flags, including `ISSUE=`, `SLUG=`,
  `SKIP_INIT`, `REQUIRE_FEATURES_COMPLETE`, `REQUIRE_AZ`, `FORCE`, and
  `DELETE_BRANCH`.
- Required outputs and state transitions, including branch naming,
  worktree naming, `.copilot-tracking/issues/issue-NN/feature_list.json`,
  `.copilot-tracking/issues/issue-NN/progress.md`, Action Log scaffolding, and
  `.copilot-tracking/review-gate/approved-head`.
- Hard failures and warning-only paths, including GitHub auth failure,
  preflight failure, malformed feature lists, missing `jq`, incomplete feature
  lists, dirty worktrees, and stale review approvals.
- Boundaries that must stay language-neutral: issue naming, worktree lifecycle,
  feature-list schema validation, review-gate state, and PR closeout.

The manifest can also include a Mermaid lifecycle source field for human review,
but the YAML is the test authority.

### Contract Sensor

Add a sensor such as `tests/scripts/test_harness_contract.sh` that reads
`docs/harness-contract.yml` and verifies the current scripts still expose the
declared behavior. The first version can be shell-based and conservative:

- Parse-check all harness scripts with `bash -n`.
- Verify every manifest-declared script exists and is executable or invokable.
- Verify declared environment flags and usage strings still appear in the owning
  script.
- Exercise the existing start/check/finish lifecycle in a temporary git repo, as
  `tests/scripts/test_issue_scaffold.sh` already does.
- Exercise review-gate approve/check failure and success paths.
- Exercise `init.sh` docs-only and language-surface detection paths.
- Fail if a lifecycle step is removed from scripts or docs without updating the
  manifest and the matching tests in the same change.

The goal is not to forbid script changes. The goal is TDD discipline: a harness
behavior change must first change the contract and tests intentionally, then
change the implementation.

### Script Unit Test Strategy

Existing script tests already cover important behavior, but profile work should
make that coverage explicit and complete before touching generators.

Required script test coverage:

- Before expanding script tests, add `.copilot/instructions/bash.instructions.md`
  for harness shell work. It should apply to `scripts/**/*.sh` and
  `tests/**/*.sh`, and cover Bash style, quoting, `set -euo pipefail`, temp-file
  cleanup, fake CLI fixtures, deterministic tests, shellcheck expectations,
  non-interactive Git/GitHub CLI usage, and when to prefer contract tests over
  byte-for-byte snapshots.
- `init.sh`: docs-only behavior, GitHub auth failure, Azure optional vs required,
  commit-signing warning, language-surface detection, missing-tool warning,
  successful gate execution, and failed gate reporting.
- `issue-lib.sh`: issue number parsing, zero-padding, slug derivation fallback,
  branch naming, worktree path naming, and main-checkout path resolution from a
  linked worktree.
- `start-issue.sh`: refuses linked-worktree invocation, runs preflight unless
  `SKIP_INIT=1`, creates deterministic branches/worktrees, does not clobber
  existing worktrees, and scaffolds `feature_list.json` plus `progress.md` with
  an Action Log.
- `check-feature-list.sh`: missing file, invalid JSON, non-object JSON,
  malformed feature entries, `passes:true` without verification, warning mode,
  and `REQUIRE_FEATURES_COMPLETE=1` hard failure.
- `review-gate.sh`: approve writes current HEAD, check passes on the same HEAD,
  check fails after HEAD changes, and missing approval fails.
- `create-pr.sh`: refuses without fresh review approval, checks again after
  rebase, preserves issue-closing trailer, and does not bypass review-gate.
- `finish-issue.sh`: refuses linked-worktree invocation, validates feature-list
  completion when present, removes clean worktrees, refuses dirty worktrees
  unless `FORCE=1`, prunes worktrees, and handles optional branch deletion.

These tests should use temporary repositories and fake `gh`, `az`, `uv`, `go`,
`pnpm`, `terraform`, `mvn`, `gradle`, and `bundle` commands where needed so they
do not depend on the developer's global machine state.

## Profile Architecture

After the contract and script sensors exist, language support should move into
declarative profiles. The harness core should know how to load profiles, detect
project surfaces, run declared gates, and report warnings. It should not know the
details of Python, Go, Node.js, Java, or Ruby directly.

### Profile Interface

Each profile must declare:

- `id`: stable profile name, such as `python`, `go`, `node`, `java`, or `ruby`.
- `detect`: files or patterns that identify the project surface.
- `variants`: optional package-manager or build-tool variants, such as
  `pnpm` vs `npm`, Maven vs Gradle, or RSpec vs Minitest.
- `sync`: optional dependency synchronization command.
- `format_check`: optional formatting check command.
- `lint`: optional lint command.
- `typecheck`: optional type-check command.
- `test`: optional test command.
- `tool_requirements`: commands that must exist to run the profile gates.
- `instructions`: matching Copilot instruction file.
- `frameworks`: supported web-framework conventions and detection hints.

Empty gate slots are valid. Go and Java usually do not need a separate
type-check command because compilation covers it. Ruby should not require a type
checker unless Sorbet or Steep is explicitly configured.

### Shipped and Generator-Supported Profiles

The shipped profile set is **Python and Node.js** (proven adopters). **Go,
Java, and Ruby** are generator-supported: `scaffold-language.sh` regenerates
them on demand from the same templates. All are specified below:

| Language | Detect | Package management | Gates | Web frameworks |
| --- | --- | --- | --- | --- |
| Python | `pyproject.toml` | `uv sync --all-groups` | ruff format, ruff check, mypy, pytest | FastAPI, Django, Flask |
| Go (scaffold skeleton) | `go.mod` | `go mod download` | gofmt, go vet, optional golangci-lint, go test | Gin, Echo, Chi, net/http |
| Node.js | `package.json` | pnpm when `pnpm-lock.yaml` or `packageManager` says pnpm; otherwise npm | prettier, eslint, optional tsc, vitest/jest/node test | Next.js, Express, NestJS |
| Java (scaffold skeleton) | `pom.xml`, `build.gradle`, or `build.gradle.kts` | Maven or Gradle wrapper | Spotless, Checkstyle or build lint, JUnit tests | Spring Boot, Quarkus |
| Ruby (scaffold skeleton) | `Gemfile` | Bundler | standardrb or RuboCop, RSpec or Minitest | Rails, Sinatra, Hanami |

Default choices should prefer project-local declarations over global defaults.
For example, Node should use `pnpm` only when the project declares it; Java
should use `./mvnw` or `./gradlew` when wrappers exist; Ruby should use the test
framework declared in the `Gemfile`.

## Generator

Add a generator such as `scripts/scaffold-language.sh <profile>` only after the
contract sensor is green. The generator should create or update language support
assets from templates instead of requiring manual copy-paste.

The generator should be idempotent and conservative:

- It must refuse unknown profiles.
- It must not overwrite existing project-specific files unless passed an explicit
  update flag and the diff is visible.
- It must create or update the matching `.copilot/instructions/<language>.instructions.md`.
- It should write version-pin hints such as `.python-version`, `.nvmrc`,
  `.java-version`, or `.ruby-version` only when requested or absent.
- It should report the exact gates the new profile will add to `init.sh`.
- It must leave issue/worktree/review-gate scripts untouched.

## Agent And Instruction Changes

Copilot agents should stop hard-coding Python instructions. Instead, agents must
load the instruction file that matches the files being changed:

- Python files load Python instructions.
- Go files load Go instructions.
- Node/TypeScript files load Node instructions.
- Java files load Java instructions.
- Ruby files load Ruby instructions.
- Mixed-language diffs load every applicable language instruction plus the core
  harness and TDD instructions.

If a language instruction file is missing, agents should fall back to the general
skill and the harness contract rather than inventing conventions.

## Delivery Plan

Work must proceed in this order so profile work cannot accidentally redefine the
harness lifecycle.

1. Add `docs/harness-contract.yml` and the harness contract sensor.
2. Expand script unit tests for existing harness behavior.
3. Refactor `init.sh` to load profile declarations while preserving current
   Python, Go, Node/pnpm, and Terraform behavior.
4. Remove Python hard-coding from agents and instruction routing.
5. Add the language scaffold generator.
6. Add Node.js profile support and tests.
7. Add Go profile support and tests.
8. Add Ruby profile support and tests.
9. Add Java profile support and tests.
10. Update `docs/HARNESS.md`, `README.md`, and `AGENTS.md` to document the
    core/profile/project-specific boundaries.

## Acceptance Criteria For The Initiative

- The existing harness lifecycle is represented in a committed YAML contract.
- A sensor validates scripts against that contract before profile refactoring
  begins.
- Existing script behaviors have targeted tests that fail on accidental behavior
  drift.
- `init.sh` can add language support through profiles rather than new hard-coded
  language branches.
- Python and current Go/Node/Terraform detection behavior remains compatible.
- Node.js, Go, Ruby, and Java support is added through profiles and tested with
  fake toolchains or minimal fixtures.
- Agents load language instructions dynamically instead of assuming Python.
- Documentation distinguishes stable harness core behavior from replaceable
  language profiles and project-specific framework conventions.