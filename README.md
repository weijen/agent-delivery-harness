# Agent Worktree Harness

A reusable Microsoft / Azure / GitHub-oriented harness for issue-driven agent
work: preflight checks, isolated worktrees, per-issue progress tracking,
deterministic quality gates, and PR closeout.

> For agents and contributors, start at [AGENTS.md](AGENTS.md). Project-specific
> product specs, architecture notes, validation plans, and delivery milestones
> should live under `docs/` and be linked from the repository map.

For the full Copilot issue lifecycle, see [docs/HARNESS.md](docs/HARNESS.md).

## Sensitivity

> Do not commit customer-supplied or confidential material such as raw media,
> screenshots, decks, exports, secrets, or local environment files. See
> [.gitignore](.gitignore) for the default suppression patterns.

## Tech Stack

- **Azure AI Foundry** — Content Understanding (video, GA), GPT-5.4 (vision +
  reasoning), GPT-4.1-nano (high-volume triage), and Code Interpreter for
  analysis workflows when a project needs them.
- **Python 3.14**, managed with [uv](https://docs.astral.sh/uv/) — added when
  the first runnable feature lands.
- **pytest** for tests (TDD), **ruff** for lint/format, **mypy** (strict) for
  type checking.
- **Terraform** for provisioned Azure resources when infrastructure work is in
  scope.

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

There are no Python gates yet — the project starts as a docs-only spec pack.
Run the docs-era gates locally when editing harness scripts or Markdown:

```sh
shellcheck scripts/*.sh               # the harness scripts themselves
markdownlint 'docs/**/*.md' '*.md'    # docs hygiene
```

When code lands, the four standard Python gates will be added by the issue
that introduces them:

```sh
uv run ruff format --check .   # auto-format check
uv run ruff check              # lint
uv run mypy                    # strict type-check
uv run pytest                  # suite (with coverage)
```

`./scripts/init.sh` already runs the Python gates when `pyproject.toml` is present.

## Harness smoke workflow

The repository has a thin GitHub Actions smoke workflow at
[.github/workflows/harness-smoke.yml](.github/workflows/harness-smoke.yml). It
only checks that harness shell scripts parse, `shellcheck` passes, and Copilot
agent/skill frontmatter is present. It is not CI/CD delivery, a deployment
pipeline, a PR watch loop, or a branch-protection required check.

## Project Layout

```text
docs/                # project-specific contracts, architecture, and status
apps/                # runnable services, agents, or tools
packages/            # shared libraries and reusable project code
infra/               # Terraform or other deployment assets when needed
scripts/             # harness shell entrypoints and shared shell library
tests/               # cross-cutting tests; per-service tests live with apps
```

All harness shell entrypoints live under `scripts/`; the repository root should not contain `.sh`
entrypoint copies.

## Where to go next

- **Project contract docs** — keep the active requirements and architecture
  under `docs/`.
- **Implementation status** — track repo-wide progress in `docs/` once project
  work starts.
- **Agents working on issues** — read [AGENTS.md](AGENTS.md) and follow the
  harness lifecycle in [docs/HARNESS.md](docs/HARNESS.md) and
  [.copilot/instructions/harness.instructions.md](.copilot/instructions/harness.instructions.md).
