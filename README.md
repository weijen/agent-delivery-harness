# Agent Worktree Harness

A reusable, **language-agnostic** harness for issue-driven agent work: preflight
checks, isolated worktrees, per-issue progress tracking, deterministic quality
gates, and PR closeout. Language support is declarative — the core ships
profiles for **Python and Node.js** (proven adopters), with **Go, Java, and
Ruby** generator-supported on demand, plus a generator for adding more (see
[docs/HARNESS.md](docs/HARNESS.md) § Harness Layers).

> For agents and contributors, start at [AGENTS.md](AGENTS.md). Project-specific
> product specs, architecture notes, validation plans, and delivery milestones
> should live under `docs/` and be linked from the repository map.

New to the harness? Start with [docs/getting-started.md](docs/getting-started.md)
for a walkthrough of standing up a new project and choosing a language.
For the full Copilot issue lifecycle, see [docs/HARNESS.md](docs/HARNESS.md).
For the harness evaluation strategy, see
[docs/evaluation/README.md](docs/evaluation/README.md).

## Sensitivity

> Do not commit customer-supplied or confidential material such as raw media,
> screenshots, decks, exports, secrets, or local environment files. See
> [.gitignore](.gitignore) for the default suppression patterns.

## Language profiles

The harness core is language-neutral. `./scripts/init.sh` detects a project's
surfaces and runs the matching gates through declarative descriptors in
`profiles/<id>.profile.sh` — it does not assume any one language. Python and
Node.js ship in `profiles/`; Go, Java, and Ruby are **generator-supported**
(regenerate any with `./scripts/scaffold-language.sh <id> --write`):

| Profile | Status | Detect | Gates |
| --- | --- | --- | --- |
| **Python** | shipped | `pyproject.toml` | ruff format, ruff check, mypy, pytest (via `uv`) |
| **Node.js** | shipped | `package.json` | prettier, eslint, optional tsc, test script (pnpm/npm) |
| **Go** | generator-supported | `go.mod` | gofmt, go vet, optional golangci-lint, go test |
| **Java** | generator-supported | `pom.xml` / `build.gradle[.kts]` | optional Spotless, Checkstyle/PMD/SpotBugs, test (Maven/Gradle) |
| **Ruby** | generator-supported | `Gemfile` | standardrb or RuboCop, RSpec or Minitest, optional Sorbet/Steep |

Terraform surfaces (`*.tf`) additionally run `terraform fmt`/`validate`. See
[profiles/README.md](profiles/README.md) for the descriptor contract and
[docs/HARNESS.md](docs/HARNESS.md) for how to add a profile with
`./scripts/scaffold-language.sh`. **Azure AI Foundry**, **Terraform**, and
similar stacks are optional layers an adopting project enables when it needs
them — they are not required by the harness itself.

## Prerequisites

- macOS or Linux (Windows via WSL2 untested).
- [GitHub CLI](https://cli.github.com/) — `gh auth login`. **Hard-required.**
- Git with commit signing configured (SSH or GPG).
- [Azure CLI](https://learn.microsoft.com/cli/azure/) — `az login`. Required
  once Foundry / Terraform work starts (`REQUIRE_AZ=1 ./scripts/init.sh`).
- [uv ≥ 0.11.9](https://docs.astral.sh/uv/getting-started/installation/) —
  required only once Python code is added. Until then, `./scripts/init.sh` warns and
  carries on.

## First-time setup

```sh
git clone https://github.com/<owner>/<repo>.git
cd <repo>
./scripts/init.sh         # preflight: gh auth, (optional) az auth, signing,
                          # uv sync IF a pyproject.toml exists, gates IF any
```

`./scripts/init.sh` is a **sensor**, not an interactive installer: it CHECKS that your
environment is healthy and exits non-zero with remediation instructions if a
hard check fails. Soft checks (Python / uv / gates) only warn while the
project still has no code.

## Quality gates

`./scripts/init.sh` runs the gates for whatever language surfaces it detects,
driven by the profile descriptors — there is no single "primary" language. A
docs-only repo (like this spec pack today) has just one required gate: shellcheck
on the harness scripts.

```sh
shellcheck scripts/*.sh               # the harness scripts themselves (required)
```

markdownlint is optional docs hygiene, not a required harness gate — run it ad hoc
if you want Markdown style feedback:

```sh
markdownlint 'docs/**/*.md' '*.md'    # optional docs hygiene (not a gate)
```

When a language surface is present, `init.sh` runs that profile's gates
automatically. For example, a Python surface (`pyproject.toml`) runs:

```sh
uv run ruff format --check .   # auto-format check
uv run ruff check              # lint
uv run mypy                    # strict type-check
uv run pytest                  # suite (with coverage)
```

Node.js surfaces run their own gates the same way; missing optional tools warn
or skip rather than failing. Go, Java, and Ruby are generator-supported —
`scaffold-language.sh` regenerates their profiles on demand. See
[profiles/README.md](profiles/README.md) for the full per-profile gate list.

## Harness smoke workflow

The repository has a GitHub Actions workflow at
[.github/workflows/harness-smoke.yml](.github/workflows/harness-smoke.yml). It
sets up `uv` and syncs the Python environment, runs the Python profile gates
(`ruff format --check`, `ruff check`, `mypy`, `pytest`), runs the harness shell
sensor suite (`tests/scripts/` and `tests/meta/`), checks that harness shell
scripts parse, runs `shellcheck`, validates Copilot agent/skill frontmatter, and
runs the L0 evaluation suite gate. A green run is a hard precondition for merge,
enforced via [scripts/merge-pr.sh](scripts/merge-pr.sh). It is not CI/CD
delivery, a deployment pipeline, or GitHub auto-merge; a repo admin may
additionally enable a branch-protection required check on `main`.

## Project Layout

```text
.copilot/            # Copilot instructions, prompts, agents, and skills
.github/workflows/   # thin harness-health smoke workflow
docs/                # harness lifecycle and project-specific docs
profiles/            # declarative language profile descriptors (+ contract)
scripts/             # harness shell entrypoints and shared shell library
tests/               # harness regression sensors
```

All harness shell entrypoints live under `scripts/`; the repository root should not contain `.sh`
entrypoint copies. Product repositories that adopt this harness can add their own `apps/`,
`packages/`, and `infra/` directories when runnable code or deployment assets land.

## Where to go next

- **Starting a new project** — follow
  [docs/getting-started.md](docs/getting-started.md) to adopt the harness, pick a
  language, scaffold its profile, and start your first issue.
- **Project contract docs** — keep the active requirements and architecture
  under `docs/`.
- **Implementation status** — track repo-wide progress in `docs/` once project
  work starts.
- **Agents working on issues** — read [AGENTS.md](AGENTS.md) and follow the
  harness lifecycle in [docs/HARNESS.md](docs/HARNESS.md) and
  [.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md).
