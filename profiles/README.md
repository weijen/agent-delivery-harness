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

### Optional gates that SKIP

A gate function may return exit code **2** to signal SKIP — the gate's tool or
project script is absent, so the gate is reported as a warning rather than a hard
failure. `scripts/init.sh` reads `PROFILE_GATE_<g>_SKIP` for the skip message.
Any other non-zero exit is a real failure (FAIL+FIX). Profiles that never opt
into SKIP (e.g. Python, whose gates only return 0/1) keep their strict hard-fail
contract; the SKIP branch stays dormant for them.

## The Node.js profile (`node.profile.sh`)

The Node descriptor exercises three optional mechanisms of the format:

- **Load-bearing variants.** `PROFILE_PM` resolves to `pnpm` when a
  `pnpm-lock.yaml` exists or `package.json`'s `packageManager` field names pnpm,
  and `npm` otherwise. The package manager drives both the surface label
  (`Node surface detected (package.json, <pm>)`) and every gate command
  (`<pm> run <script>`).
- **Conditional gate slot.** `typecheck` is included only for TypeScript
  projects — detected via `tsconfig.json`, a `typecheck` script, or `*.ts`
  sources. JS-only projects omit the slot (empty-slot rule), so
  `PROFILE_GATES` is `(format_check lint test)` instead of
  `(format_check lint typecheck test)`.
- **Optional gates that SKIP.** `format_check`, `lint`, and `typecheck` prefer
  the project's declared script and fall back to the default tool
  (`prettier`/`eslint`/`tsc`); when neither is available the gate returns 2 and
  is reported as a skip. The `test` gate falls back across
  `vitest` → `jest` → `node --test` before skipping.

Because Node's metadata would clobber the shared `PROFILE_*` globals, `init.sh`
sources `node.profile.sh` **late** — after the Python gate loop has run — and
reads the surface label up front via a one-shot subshell source.

## The Go profile (`go.profile.sh`)

The Go descriptor shows the **empty-slot** and **optional-SKIP** rules without
package-manager variants:

- **No `typecheck` slot.** `PROFILE_GATES` is
  `(format_check lint golangci test)` — compilation via `go vet` / `go test`
  covers type checking, so a separate typecheck slot is omitted.
- **Single toolchain.** `PROFILE_VARIANTS` is empty; Go has one toolchain.
- **Non-mutating format check.** `format_check` runs `gofmt -l .` (list mode) so
  validation never rewrites files; a non-empty listing fails the gate and the FIX
  hint points at `gofmt -w .`.
- **Optional `golangci-lint`.** The `golangci` gate runs `golangci-lint run`
  when the linter is installed and otherwise SKIPs (returns 2 → warn); `go vet`
  still provides baseline static analysis.
- **Framework hints.** `PROFILE_FRAMEWORKS` lists `Gin Echo Chi net/http`
  without forcing any framework.

Like Node, the Go descriptor is sourced **late** so its `PROFILE_*` globals do
not clobber Python's before the Python gate loop runs.

## The Ruby profile (`ruby.profile.sh`)

The Ruby descriptor carries **two** load-bearing variant axes plus a conditional
typecheck slot:

- **Lint/format variant.** `PROFILE_RUBY_LINTER` is `standardrb` or `rubocop`.
  An existing RuboCop setup (`.rubocop.yml` or the `rubocop` gem) wins; otherwise
  the descriptor prefers **Standard Ruby** for low-configuration lint+format.
  Standard Ruby is a **combined lint/format path**, so it occupies the single
  `lint` slot (no separate `format_check`); its OK message signals
  `lint+format`.
- **Test-framework variant.** `PROFILE_RUBY_TEST` is `rspec` (a `spec/` dir or
  the `rspec` gem) or `minitest` (the standard-library default), and drives the
  test gate command (`bundle exec rspec` vs `bundle exec rake test`).
- **Conditional typecheck.** No type checker is required unless the project
  explicitly configures **Sorbet** (`sorbet/config` or the gem) or **Steep**
  (`Steepfile` or the gem); only then is a `typecheck` slot appended
  (`bundle exec srb tc` / `bundle exec steep check`).
- **Optional gates that SKIP.** Every gate runs through `bundle exec` and
  returns 2 (SKIP → warn) when `ruby`/`bundler` is not installed.
- **Framework hints.** `PROFILE_FRAMEWORKS` lists `Rails Sinatra Hanami` without
  forcing any framework.

The surface label is `Ruby surface detected (Gemfile, <linter>/<test>)`. Like Go
and Node, the Ruby descriptor is sourced **late** so its `PROFILE_*` globals do
not clobber Python's before the Python gate loop runs.

- Prefer project-local declarations over global defaults (e.g. Node uses pnpm
  only when the project declares it; Java prefers `./mvnw`/`./gradlew`).
- Keep descriptors `bash` 3.2-compatible and `shellcheck`-clean.
- `instructions` and `frameworks` may be declared-but-unused for now; they are
  consumed by issue #36 (instruction routing) and the per-language profile
  issues (framework hints) respectively.
