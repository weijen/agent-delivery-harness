# `scripts/` Portfolio Review — Bash at Scale: Inventory, Language Choice, Consolidation

**Date:** 2026-07-09
**Scope:** all 22 scripts (6,994 lines of bash) + their 136 test files (27,331 lines of bash tests)
**Questions asked:** (1) we keep growing in bash — should we migrate to Python or another
language before maintenance gets hard? (2) does the portfolio need re-planning/consolidation?

> **2026-07-10 note:** The trace_tools/export pilot described in this
> historical rationale record was reverted by issue #272. The rest of this
> document is preserved as the original review context.

---

## Executive summary

The portfolio is **two different codebases sharing a directory**, and the two questions have
opposite answers for each:

| Cluster | Lines | Nature | Verdict |
| --- | --- | --- | --- |
| **Lifecycle core** (init, start/finish-issue, create/merge-pr, review-gate, libs, installer, scaffolder) | ~2,230 | Orchestration of git/gh/worktrees | **Stays bash.** This is what bash is best at, and the architecture (frozen contract, zero-toolchain installer) depends on it. |
| **Trace subsystem** (trace-lib, export, validate, report, scorecard, consistency, reconstruct, sanitize, 2 hooks, log-handback, check-feature-list) | ~4,770 | Half orchestration, half **data programs written in jq-inside-bash** | **Split.** Emission/hooks stay bash. The six analytics tools are already "Python programs wearing a bash costume" — migrate them behind their existing CLI contracts, staged and trigger-based. |

The pain is not "bash at 7,000 lines". The pain is **~600 lines of jq programs embedded in
heredocs** — schema mappers, validators, and aggregators that are real programs in a language
with no types, no debugger, no unit-test seams, and no code sharing (the same `allowlist` def is
byte-duplicated twice inside `trace-export.sh` alone). That is where maintenance cost is
compounding, and it is concentrated in 6 files.

**Recommended path:** consolidate in bash now (Phase 0, cheap), pilot one Python migration when
the next trace-analytics feature lands (Phase 1 — #163 cloud cost dashboard is the natural
trigger), and never migrate the lifecycle core or the hooks.

---

## 1. Inventory

### Lifecycle core (~2,230 lines) — bash-natural

| Script | Lines | Responsibility | Churn* |
| --- | --- | --- | --- |
| `init.sh` | 305 | Preflight sensor: hard/soft tool checks, profile-driven surface gates | 9 |
| `finish-issue.sh` | 295 | Teardown: worktree removal, completion check, trace export/reconstruct/hygiene | 9 |
| `scaffold-language.sh` | 284 | Generate profile descriptor + instructions skeleton | – |
| `start-issue.sh` | 232 | Worktree + branch + per-issue scaffold | 6 |
| `review-gate.sh` | 448 | 5 gates: approval marker, status-doc, ci-coverage, trace, red-first | 6 |
| `install-harness.sh` | 173 | Copy harness into target repo (dry/write/update) | – |
| `create-pr.sh` | 146 | Rebase onto main, dual gate check, push, open PR | 4 |
| `merge-pr.sh` | 134 | CI-green gate, squash merge | – |
| `ci-coverage-lib.sh` | 96 | Detect code surfaces lacking project CI | – |
| `issue-lib.sh` | 84 | Issue → branch/worktree/tracking-dir naming (single source) | – |

\* commits touching the file in the last ~120 commits.

Characteristics: state mutation of git/GitHub/filesystem; almost no JSON manipulation (one
cosmetic `--jq` in init.sh); POSIX-portable, no macOS/Linux hacks; single-responsibility per
script with one justified mini-CLI (`review-gate.sh` subcommands).

### Trace subsystem (~4,770 lines) — mixed

| Script | Lines | Responsibility | Largest embedded jq | Churn |
| --- | --- | --- | --- | --- |
| `trace-export.sh` | 900 | Map spans → App Insights / OTLP envelopes, fail-closed gates, curl ship | **114 + 114 lines** | 6 |
| `copilot-trace-hook.sh` | 576 | Copilot runtime hook: tool/agent/model spans, interval attribution | 31 jq call sites | 8 |
| `check-trace-consistency.sh` | 1,608 | Schema/type/redaction + trace ↔ progress.md ↔ feature_list cross-checks | 145 lines | – |
| `trace-report.sh` | 396 | Per-issue aggregation → summary JSON + markdown | **141 lines** | 5 |
| `trace-lib.sh` | 388 | `trace_span` emission, redaction, portable clock, main-root pinning | 37 lines | 8 |
| `trace-scorecard.sh` | 368 | Cross-run aggregation by harness version | 90 lines | 4 |
| `trace-reconstruct.sh` | 296 | Backfill tool spans from Copilot transcripts | moderate | 3 |
| `claude-code-trace-hook.sh` | 285 | Claude Code runtime hook | moderate | – |
| `log-handback.sh` | 279 | Single-source agent span + Action Log line | small | – |
| `sanitize-trace.sh` | 256 | Real trace → commit-safe fixture, 4-layer leak audit | jq walk | – |
| `check-feature-list.sh` | 180 | feature_list.json structural/completion check | small | – |

### Constraints that bound any decision

- **Architecture commitment** (`docs/HARNESS.md`): Core Harness is language-neutral, behavior
  frozen in `docs/harness-contract.yml`, guarded by `test_harness_contract.sh`. Hard runtime
  requirements today: `git`, `gh`, `sed`, `grep`, `bash 3.2+`. `jq` is required by the trace
  subsystem, soft elsewhere.
- **Installer footprint**: `install-harness.sh` assumes only POSIX tools in the target repo.
  Language toolchains are lazy-checked at `init.sh` time.
- **Test suite**: 27,331 lines of bash tests — **4× the production code**. Crucially, they test
  the scripts **as CLIs** (args in, exit codes 0/1/2 out, output shapes) with fake `gh`/tool
  binaries. This is the single most important fact for the migration question (§2.3).
- **This repo has zero Python today** (no `pyproject.toml`). Introducing Python makes the
  harness itself a Python-surface project — its own `init.sh`/`ci-gate` gates would start
  applying to it (which is fine, even good dogfooding, but it is a real step).

---

## 2. Question 1 — should we move to Python?

### 2.1 Where bash is winning (keep it)

The lifecycle core is **thin orchestration over git/gh** — worktree creation, rebase flows,
`gh pr checks` gating, file scaffolding. Rewriting `create-pr.sh` in Python means calling the
same `git`/`gh` binaries through `subprocess` with more ceremony and a new runtime dependency,
for zero expressiveness gain. Both analysis passes independently classified all ten lifecycle
scripts as bash-natural. Combined with the frozen-contract commitment and the POSIX-only
installer, **the lifecycle core should stay bash indefinitely.**

The same applies to the **hot emission path**: `trace-lib.sh` (`trace_span`), `log-handback.sh`,
and both runtime hooks. The hooks have a hard session-safety contract — exit 0 with empty stdout
on *every* path, because a non-zero exit can deny the agent's tool call — and they run inline
with every tool invocation. A Python interpreter launch per tool call is exactly the overhead
and the new failure mode (missing/broken interpreter mid-session) this contract exists to avoid.

### 2.2 Where bash is losing (migrate this)

The six trace analytics tools are **data programs, not orchestration**:

- `trace-export.sh` — two 114-line jq programs (schema→envelope mappers with 8 and 5 function
  definitions, TimeSpan arithmetic, hex trace-id derivation), a hand-wired HTTP transport, and
  a 4-layer fail-closed audit. The `allowlist`/`shippable_key` defs are **byte-duplicated**
  between the two programs because jq-in-heredoc has no import mechanism.
- `check-trace-consistency.sh` — a 109-line single-pass jq filter carrying schema + types + enums +
  sanity flags, deliberately monolithic to avoid per-line process forks (a constraint Python
  simply doesn't have).
- `trace-report.sh` — a 141-line jq aggregation (token bucketing with absence-vs-zero
  semantics, loop-indicator grouping via reduce, red-reentry state tracking) that would be
  ~40 lines of readable Python with `collections`.
- `trace-scorecard.sh` — 90-line jq cross-run aggregation with version-attribution case logic.
- `check-trace-consistency.sh` — three separate passes in three tool families (awk/sed/comm
  multiset diff, two jq filters) over the same inputs; one Python pass would read
  trace + progress.md + feature_list once and evaluate all rules.
- `sanitize-trace.sh` — decode-aware scrubbing split across sed and jq-walk layers.

These exhibit the classic signals of the wrong language: duplicated defs because there is no
module system, arithmetic and date math in jq/bash string space, "one giant filter" as a
process-count optimization, and logic split across awk/sed/comm/jq because no single tool holds
the whole problem. Every future trace feature (e.g. **#163 cost dashboard**) lands on this pile.

### 2.3 Why migration is cheaper than it looks — the CLI contract insight

The 27k-line bash test suite tests these tools **as black-box CLIs**: same args, same exit-code
semantics (0 clean / 1 violation / 2 usage), same output files. If a Python implementation
preserves the CLI contract, **the existing test suite keeps working unchanged** and serves as
the migration's regression harness — including the mutation-tested oracles (the lifted #92
schema filter, the multiset detector) that pin behavior byte-precisely. This converts the
biggest apparent migration cost (27k lines of tests) into the migration's safety net.

### 2.4 Why the dependency risk is smaller than it looks — the optional-subsystem insight

The trace analytics are already **optional and guarded**: lifecycle scripts source trace-lib
with a NOOP fallback, `finish-issue.sh` runs export/reconstruct best-effort, the trace gate is
warn-only unless `REQUIRE_TRACE_CONSISTENCY=1`. Python can therefore be an **optional dependency
of an already-optional subsystem**: if `python3` (or `uv`) is absent, the analytics skip with
the same explicit-warning pattern the harness already uses everywhere else. The core lifecycle
keeps its git+gh-only footprint. (Note: `python3` is *already* a soft dependency —
`trace-lib.sh:131` uses it as a clock fallback.)

### 2.5 Verdict and staged plan

**Do not migrate wholesale. Migrate the analytics layer, trigger-based, behind frozen CLIs.**

- **Phase 0 — consolidate in bash (now, cheap):** the §3 items. No language change.
- **Phase 1 — pilot (trigger: the next substantive trace-analytics feature, realistically
  #163):** implement ONE tool in Python — best candidate `trace-report.sh` or the mapping half
  of `trace-export.sh` — as `scripts/trace_tools/` (uv-managed, `uv run python -m ...`), keeping
  the existing `.sh` file as a thin dispatcher: use Python when available, else today's jq path
  (or a hard skip with warning). Existing bash tests must stay green against both paths.
  **Decision gate:** after the pilot, compare the diff-size and review effort of implementing
  the trigger feature in Python vs. what the jq equivalent would have cost. Continue only on a
  clear win.
- **Phase 2 — migrate the remaining five analytics** (validate, scorecard, consistency,
  sanitize, export transport last since curl is fine). Retire the jq paths once parity holds
  across adopting repos.
- **Never migrate:** lifecycle core, `trace-lib.sh` emission, `log-handback.sh`, both hooks.

Why not Go/Rust (single static binary, zero runtime deps)? Defensible for the hooks one day,
but for the analytics layer the write-and-review loop matters more than distribution, the
harness already carries a Python profile/instructions ecosystem, and agents (the primary
maintainers here) produce more reliable Python. Revisit only if adopting repos report `python3`
availability as a real friction.

---

## 3. Question 2 — re-planning and consolidation

Findings ordered by payoff; none require the language decision first.

### P-1: Extract the 5× trace-guard + EXIT-trap boilerplate (highest mechanical payoff)

`start-issue.sh`, `create-pr.sh`, `merge-pr.sh`, `finish-issue.sh`, `review-gate.sh` each carry
an identical ~15-line guarded `source trace-lib.sh` + NOOP fallback block, plus a near-identical
~20-line `TRACE_STAGE`/`trap ... EXIT` lifecycle-span template. Move both into `trace-lib.sh`
itself (a `trace_lifecycle_init <step>` helper): ~120 lines deleted, and the next lifecycle
script can't fork the pattern. This is precisely the drift the meta-sensors elsewhere guard
against.

### P-2: Dedupe the jq `allowlist`/`shippable_key` defs inside trace-export.sh

Byte-duplicated between the OTLP and App-Insights filters. Short-term bash fix: emit the shared
defs from a single heredoc variable prepended to both programs (or a `.jq` file shipped beside
the script — but that changes the install manifest). Becomes moot if Phase 1/2 lands; do it now
only if #163 arrives before the pilot. `fmt_duration` (TimeSpan math) is likewise duplicated
between trace-export and trace-report.

### P-3: Reconcile-logic duplication between install-harness.sh and scaffold-language.sh

The dry/write/update three-way diff-and-copy logic is implemented twice (~40 lines each).
Extract `scripts/reconcile-lib.sh` — and add it to the `install-harness.sh` asset manifest.

### P-4: finish-issue.sh is becoming a second conductor

295 lines, 9 helper functions, chains three external tools plus state hygiene. It is the
fastest-growing lifecycle script (churn 9). Keep it an orchestrator: its best-effort helpers
(`best_effort_trace_export`, `_reconstruct`, `_state_hygiene`) already have clean seams — split
them into a sourced `finish-lib.sh` (or fold into trace-lib) before the next feature lands
there, keeping `finish-issue.sh` under ~150 lines of sequence.

### P-5: copilot-trace-hook interval fallback — fix the architecture, not the code

The hook's O(N)-scan interval attribution (lexicographic ISO-timestamp comparison over every
issue's trace windows) is the most fragile logic in the portfolio, and it exists because the
hook must *discover* the active issue after the fact. The lifecycle already knows the answer:
`start-issue.sh` could write an active-issue marker (issue + window start) that the hook reads
directly, demoting the interval scan to a last resort. This also shrinks the undocumented
`events.jsonl` surface the hook currently leans on. Worth an issue of its own; it reduces
576 lines of the second-most-churned script.

### P-6: review-gate.sh — split threshold, not split now

Five gates in 448 lines is defensible (shared approval-marker state, shared trap). Adopt an
explicit rule: next gate added → split into `review-gate.d/` gate files with `review-gate.sh`
as dispatcher. Don't reorganize preemptively; the frozen contract names this script.

### P-7: Directory shape — leave it flat

A `scripts/trace/` subdirectory looks tempting (12 of 22 files are trace-related) but
`harness-contract.yml` freezes script paths, `install-harness.sh` manifests them, hooks are
installed by absolute path in runtime configs, and 136 test files reference `scripts/*.sh`
literally. The reorganization cost is real and the benefit is cosmetic. If Phase 1 lands,
`scripts/trace_tools/` (new Python package) gives the trace subsystem a home without moving any
frozen path.

### P-8: No unified `harness` CLI

Single-purpose scripts invoked piecemeal (by agents, docs, and CI) are a feature — each is
independently promptable and testable. A branded CLI adds a dispatch layer with no new
capability. Skip.

---

## 4. Suggested issue breakdown

1. **[feat] scripts: extract shared trace-guard/EXIT-trap helper into trace-lib (P-1)** — plus
   drift sensor forbidding a fresh inline copy. Small, high payoff.
2. **[feat] scripts: extract reconcile-lib shared by install-harness/scaffold-language (P-3)** —
   small.
3. **[feat] scripts: split finish-issue best-effort helpers into a sourced lib (P-4)** — small,
   do before the next finish-issue feature.
4. **[feat] trace: active-issue marker written at start-issue; hook interval-scan becomes last
   resort (P-5)** — medium; biggest fragility reduction available without a language change.
5. **[spike] trace: Python pilot for one analytics tool behind its existing CLI (Phase 1)** —
   explicitly gated on the next trace-analytics feature (likely #163); includes the
   decision-gate comparison and the optional-dependency skip path. P-2 folds into it (or lands
   as a micro-fix if #163 comes first).
6. **[docs] harness: record the language policy (P-6/P-7/P-8 + §2.5 verdict)** — one page in
   docs/ stating what stays bash, what may become Python, and the split thresholds, so future
   sessions don't relitigate it.

## 5. What NOT to do

- Don't rewrite lifecycle scripts in Python for uniformity — it trades a working, contract-frozen
  orchestration layer for a new runtime dependency with zero expressiveness gain.
- Don't migrate the hooks off bash — the exit-0/empty-stdout session-safety contract and
  per-tool-call latency budget rule out interpreter startup.
- Don't port tests to pytest as part of migration — the bash suite testing CLI contracts IS the
  migration safety net; port tests only for genuinely new Python-internal logic.
- Don't reorganize the directory or introduce a mono-CLI — frozen paths, cosmetic benefit.
