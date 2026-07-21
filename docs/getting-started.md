# Starting a New Project

This guide walks through standing up a new project on the harness: adopting the
harness, choosing a language, scaffolding the matching profile, running
preflight, and starting your first issue. It is the onboarding companion to the
[README](../README.md) (overview and setup) and
[docs/HARNESS.md](HARNESS.md) (the full issue lifecycle).

## 1. Decide how to adopt the harness

The harness core is **language-agnostic** — it ships the issue lifecycle,
worktrees, gates, and PR closeout, and learns a language only through a profile
descriptor. There are two common ways to start:

- **Use this repository as the project root.** Clone it and start adding your
  code under `apps/`, `packages/`, or `infra/` as it lands. The harness scripts
  in `scripts/` and the profiles in `profiles/` stay where they are.
- **Copy the harness into an existing project.** Run the installer, which copies
  the real harness assets — `scripts/`, `profiles/`, `tests/scripts` and
  `tests/meta`, `.copilot/instructions/`, `.copilot/agents/`, `.copilot/skills/`,
  `.copilot/prompts/`, `.github/workflows/harness-smoke.yml`, and the lifecycle
  and runtime contract docs. It also copies the trace and log schemas,
  `docs/runtime-adapters/` guides and templates, and `VERSION` identity into a
  target directory verbatim, touching nothing else:

  ```sh
  ./scripts/install-harness.sh /path/to/project            # dry run — prints what it would copy
  ./scripts/install-harness.sh /path/to/project --write    # copy missing assets (never clobbers a differing file)
  ./scripts/install-harness.sh /path/to/project --update   # overwrite a differing asset (after showing the diff)
  ```

  It defaults to a dry run, never overwrites a target file that differs without
  `--update`, and leaves your project's own code in place. All
  `.copilot/instructions/*` are installed, including the language-specific ones
  (`python`, `terraform-azure`) — delete whichever you do not need.

Either way, project-specific product specs, architecture notes, and delivery
plans live under `docs/` and are linked from [AGENTS.md](../AGENTS.md).

## 2. Check prerequisites

Before anything else, make sure the hard requirements from the
[README](../README.md#prerequisites) are met:

- macOS or Linux (Windows via WSL2 is untested).
- [GitHub CLI](https://cli.github.com/) authenticated — `gh auth login`. **Hard-required.**
- Git with commit signing configured (SSH or GPG).
- [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az login`) only once
  Azure / Terraform work starts — run `REQUIRE_AZ=1 ./scripts/init.sh` then.
- Language toolchains are needed only once that language's code exists (for
  example [uv](https://docs.astral.sh/uv/) for Python). Until then preflight
  warns and carries on.

## 3. Choose a language

Pick the language for your project's first surface. The harness ships profiles
for **Python and Node.js**; **Go, Java, and Ruby** are generator-supported
(scaffold on demand). Each is detected by a marker file and runs its own gates:

| Language | Status | Detect | Gates | Web framework hints |
| --- | --- | --- | --- | --- |
| **Python** | shipped | `pyproject.toml` | ruff format, ruff check, mypy, pytest (via `uv`) | FastAPI, Django, Flask |
| **Node.js** | shipped | `package.json` | prettier, eslint, optional tsc, test script (pnpm/npm) | Next.js, Express, NestJS |
| **Go** | generator-supported | `go.mod` | gofmt, go vet, optional golangci-lint, go test | Gin, Echo, Chi, net/http |
| **Java** | generator-supported | `pom.xml` / `build.gradle[.kts]` | optional Spotless, Checkstyle/PMD/SpotBugs, test (Maven/Gradle) | Spring Boot, Quarkus |
| **Ruby** | generator-supported | `Gemfile` | standardrb or RuboCop, RSpec or Minitest, optional Sorbet/Steep | Rails, Sinatra, Hanami |

Terraform surfaces (`*.tf`) additionally run `terraform fmt`/`validate`. A
project can carry more than one surface — `init.sh` detects each and runs the
matching gates. A docs-only repo (like this one today) needs only `shellcheck`
on the harness scripts.

See [profiles/README.md](../profiles/README.md) for the descriptor contract and
the full per-profile gate list, and
[docs/multi-language-profiles.md](multi-language-profiles.md) for the design.

## 4. Scaffold the profile (only if it is missing)

The Python and Node.js profiles ship under `profiles/`; Go, Java, and Ruby are
generator-supported. You only need the generator when you want to (re)create a
profile's descriptor and its matching Copilot instruction file:

```sh
./scripts/scaffold-language.sh <python|go|node|java|ruby>          # dry run — prints what it would do
./scripts/scaffold-language.sh <profile> --write                  # create missing assets
./scripts/scaffold-language.sh <profile> --update                 # overwrite a differing asset (after showing the diff)
```

The generator is idempotent and conservative: it refuses unknown profiles, only
writes under `profiles/` and `.copilot/instructions/`, reports the gates the
profile adds to `init.sh`, and never touches the issue lifecycle scripts. To add
support for a language beyond the built-in five, follow
[docs/HARNESS.md § Adding or updating a language profile](HARNESS.md#adding-or-updating-a-language-profile).

## 5. Run preflight

`./scripts/init.sh` is a **sensor**, not an installer: it verifies your
environment is healthy and runs the gates for whatever surfaces it detects.

```sh
./scripts/init.sh             # gh auth, (optional) az auth, signing, sync + gates if any
REQUIRE_AZ=1 ./scripts/init.sh # when the work needs Azure / Terraform
```

Hard checks (GitHub auth, signing) fail with remediation instructions; soft
checks (a missing language toolchain or absent gates) only warn while the
project still has no code.

## 6. Start your first issue

The harness is issue-driven. Create a GitHub issue with concrete acceptance
criteria, then start it from the **main checkout**:

```sh
./scripts/start-issue.sh 1    # runs preflight, then creates branch
                              # feature/issue-01-<slug> + an isolated worktree
cd ../<repo>-worktrees/issue-01
```

From there, follow the lifecycle in [docs/HARNESS.md](HARNESS.md): populate
`.copilot-tracking/issues/issue-NN/feature_list.json`, work one feature at a
time with the subagents, run the review gate, open a PR with
`./scripts/create-pr.sh`, and close out with `./scripts/finish-issue.sh`.

## 7. Subagent permissions

The harness uses subagents (generator, reviewer, planner) that invoke harness
scripts on your behalf. Before spawning subagents, establish the intended
authorization mode explicitly — see the layers below.

**Provenance key for this section:**
- **(Documented)** — per official GitHub Docs
  ([Copilot CLI tool approval](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-copilot-cli)):
  when Copilot wants to use a tool that modifies or executes something in
  interactive mode, it asks for approval; the user may approve once, or approve
  for the running session with any options or any arguments for that tool.
- **(Observed on CLI 1.0.72-1, issue #319)** — behavior seen in this harness
  run but not guaranteed stable across CLI versions.
- **(Environment-specific)** — capability that varies by deployment, org
  policy, or configuration; verify locally.

**Observed symptom (CLI 1.0.72-1, issue #319):** if the conductor launches
several subagents and their tool-approval prompts are not surfaced (for example,
in a background or nested context), unanswered prompts queue up and create a
**permission denial storm** — the subagent retries, gets denied again, and the
issue run stalls silently with no work produced.

The harness documents three layers of permission control, from narrowest to
broadest. Choose the narrowest layer your environment supports. If behavior
differs from what is described, stop and resolve visible prompts rather than
falling back to `/allow-all`.

### Layer 1: Tool-level session approval (documented)

**(Documented)** When Copilot wants to use a tool that modifies or executes
something in interactive mode, it asks for approval. The user may approve that
tool once, or approve it for the rest of the running session — approval applies
with any options or any arguments for that tool within the session. This is the
built-in CLI mechanism per official GitHub Docs; no additional configuration is
required.

### Layer 2: Environment-specific exact-command allowlisting

**(Environment-specific)** Some Copilot environments, organization policies, or
deployment configurations may expose an exact-command or exact-script allowlist
capability. If your environment supports this, example harness entrypoints you
might scope include:

- `scripts/log-handback.sh` — logs conductor↔subagent handback events
- `scripts/review-gate.sh` — runs the review gate checks

These are examples, not an exhaustive list — additional harness scripts may be
invoked depending on the issue workflow. Verify the exact configuration syntax
and available options in your environment's policy UI or documentation; this
guide intentionally provides no guessed configuration syntax because the
capability and its interface vary across environments.

### Layer 3: Explicit `/autopilot` handoff (observed operational authorization)

**(Observed on CLI 1.0.72-1, issue #319)** The `/autopilot` slash-command was
the operational authorization used in this harness run. Issuing `/autopilot` at
the conductor level before spawning subagents allowed the autonomous run to
proceed without per-tool prompts in that session. Official GitHub Docs list
`/autopilot` as a CLI slash-command but do not define its exact permission
semantics; behavior may vary across CLI versions.

The key requirement observed: the `/autopilot` handoff should happen before
subagents are spawned — not after a denial storm has already begun.

### What NOT to do: permanent blanket allow-all is an anti-pattern

**(Documented)** The CLI offers `/allow-all` (and the `--allow-all` launch flag)
for trusted situations — official docs acknowledge this exists. However, using
it as a **permanent standing configuration** across all sessions is an
**anti-pattern** for harness work:

- Defeats the principle of least privilege — any command a compromised or
  misbehaving agent emits will execute without review.
- Masks misconfiguration — you will never notice when a subagent tries an
  unexpected command because nothing is ever denied.

This harness prefers narrower session-scoped permission (Layer 1 or Layer 2) or
deliberate `/autopilot` handoff (Layer 3) over a permanent blanket allow-all.
If you encounter a permission denial storm, the correct fix is one of the layers
above, not a standing blanket rule.

## Where to go next

- [AGENTS.md](../AGENTS.md) — the map agents and contributors start from.
- [docs/HARNESS.md](HARNESS.md) — the full issue lifecycle and CI boundary.
- [profiles/README.md](../profiles/README.md) — the profile descriptor contract.
- [docs/evaluation/README.md](evaluation/README.md) — the harness evaluation strategy.
