# Harness language profiles

This directory holds the harness's **language profile descriptors**. A profile
moves a language's surface detection, dependency sync, and quality gates out of
hard-coded branches in `scripts/init.sh` and into a declarative, committed file.
The harness core loads profiles, detects the project surface, runs the declared
gates, and reports warnings — it does not hard-code the details of Python, Go,
Node.js, Java, or Ruby.

This is the descriptor format introduced in issue #35; the Python profile is the
first descriptor. Later issues add Go, Node.js, Ruby, and Java profiles and a
generator (`scripts/scaffold-language.sh`).

> **Scaffolding a new profile:** run `scripts/scaffold-language.sh <profile>`
> (one of `python go node java ruby`) to preview the skeleton descriptor and
> instruction file it would create; add `--write` to apply, or `--update` to
> overwrite an existing asset after showing the diff. The generator is
> idempotent and never touches the issue lifecycle scripts.

## File format

Each profile is a Bash-sourced descriptor named `<id>.profile.sh` (for example
`python.profile.sh`). `scripts/init.sh` sources the descriptor and reads its
variables / calls its functions. Bash was chosen so command invocation stays
byte-identical to the previous hard-coded branches and no parser is required.

A descriptor declares the spec's **Profile Interface** fields:

| Field | How it is expressed | Purpose |
| --- | --- | --- |
| `id` | `PROFILE_ID` | Stable profile name (`python`, `go`, `node`, `java`, `ruby`). |
| `detect` | `PROFILE_DETECT` + `profile_detect()` | Files/patterns identifying the surface; the function returns success when the surface is present. |
| `variants` | `PROFILE_VARIANTS` | Optional package-manager / build-tool / test-framework variants (e.g. pnpm vs npm, Maven vs Gradle, RSpec vs Minitest). May be empty. |
| `sync` | `PROFILE_SYNC_*` + `profile_sync()` | Optional dependency synchronization command and its OK/FAIL/FIX messages. |
| `format_check` | gate slot `format_check` | Optional formatting check command. |
| `lint` | gate slot `lint` | Optional lint command. |
| `typecheck` | gate slot `typecheck` | Optional type-check command. |
| `test` | gate slot `test` | Optional test command. |
| `tool_requirements` | `PROFILE_TOOL_REQUIREMENTS` | Command(s) that must exist to run the gates. |
| `instructions` | `PROFILE_INSTRUCTIONS` | Matching Copilot instruction file (consumed by issue #36). |
| `frameworks` | `PROFILE_FRAMEWORKS` | Supported web-framework hints (consumed by the per-language profile issues). |

### Gate slots

Quality gates are declared as an ordered array:

```bash
PROFILE_GATES=(format_check lint typecheck test)
```

Each slot `<g>` provides:

- a command function `profile_gate_<g>` (exit 0 = pass);
- three message strings `PROFILE_GATE_<g>_OK`, `PROFILE_GATE_<g>_FAIL`, and
  `PROFILE_GATE_<g>_FIX` (the remediation hint).

`scripts/init.sh` iterates `PROFILE_GATES` in order, runs each function, and
prints OK or FAIL+FIX accordingly.

### Empty-slot rule

Empty gate slots are valid. A language without a separate type-check or format
command simply omits that slot from `PROFILE_GATES`. Go and Java usually have no
separate `typecheck` (compilation covers it); Ruby needs no type checker unless
Sorbet/Steep is configured. `PROFILE_VARIANTS` may also be empty for a language
with a single package manager (as Python's `uv`).

## Conventions

- Prefer project-local declarations over global defaults (e.g. Node uses pnpm
  only when the project declares it; Java prefers `./mvnw`/`./gradlew`).
- Keep descriptors `bash` 3.2-compatible and `shellcheck`-clean.
- `instructions` and `frameworks` may be declared-but-unused for now; they are
  consumed by issue #36 (instruction routing) and the per-language profile
  issues (framework hints) respectively.
