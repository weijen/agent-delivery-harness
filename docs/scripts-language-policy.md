# Scripts language & structure policy

**Status:** policy of record for `scripts/`.
**Rationale:** [docs/scripts-portfolio-review.md](scripts-portfolio-review.md) (§2.5, P-6, P-7, P-8).

This page records, in one place, what language `scripts/` is written in, what may
change, and when the directory is allowed to grow structure — so future sessions
do not relitigate it. The *why* lives in the portfolio review; this page is the
short, enforceable verdict.

The portfolio is really **two codebases sharing one directory**: a **lifecycle
core** (orchestration of git / `gh` / worktrees) and a **trace subsystem** (half
orchestration, half data programs written as jq-inside-bash). The two clusters get
opposite answers, so the policy is stated per cluster.

## 1. Stays bash — indefinitely

These never migrate. They are orchestration glue where bash is the right tool, and
the architecture (frozen contract, zero-toolchain installer, session-safe hooks)
depends on them staying interpreter-free:

- **Lifecycle core:** `init.sh`, `start-issue.sh`, `finish-issue.sh`,
  `create-pr.sh`, `merge-pr.sh`, `review-gate.sh`, the sourced libs
  (`issue-lib.sh`, `reconcile-lib.sh`), the installer (`install-harness.sh`) and
  the scaffolder (`scaffold-language.sh`).
- **Trace emission:** `trace-lib.sh` and `log-handback.sh`.
- **Both runtime hooks** (`copilot-trace-hook.sh`, `claude-code-trace-hook.sh`).
  Their session-safety contract — **exit 0 with empty stdout on every path, no
  interpreter startup per tool call** — makes an interpreted rewrite a
  non-starter.

## 2. May become Python — trigger-based, never wholesale

Only the **six trace-analytics tools** are candidates: `trace-export.sh`,
`validate-trace.sh`, `trace-report.sh`, `trace-scorecard.sh`,
`check-trace-consistency.sh`, and `sanitize-trace.sh`. They are already "Python
programs wearing a bash costume" (~600 lines of jq in heredocs, no types, no
debugger, no unit-test seams).

Migration is allowed **only** under all of these conditions:

- **Behind the existing CLI contracts** — same args, same exit codes (0 / 1 / 2),
  same output files — with the current **bash test suite as the regression
  harness** (it must stay green against both the Python and the jq path).
- **Trigger-based:** only when a substantive trace-analytics feature makes the jq
  path the more expensive option. Do not migrate speculatively. See the gated
  pilot issue for the first candidate and its decision gate.
- **Staged:** pilot exactly one tool first (thin `.sh` dispatcher → Python when
  available, else today's jq path), evaluate the diff-size / review-effort win at
  the decision gate, and only then migrate the rest.

A new Python package lives at **`scripts/trace_tools/`** (uv-managed,
`uv run python -m ...`) so it gets a home without moving any frozen path. Go / Rust
were considered and rejected for the analytics layer: the write-and-review loop
matters more than single-binary distribution, and the harness already carries a
Python profile/instructions ecosystem.

## 3. Structure — split thresholds, not preemptive reorganization

- **`review-gate.sh` splits into `review-gate.d/`** gate files (with
  `review-gate.sh` as the dispatcher) **when the next gate is added — not
  before.** Five gates in one file is defensible today (shared approval-marker
  state, shared trap).
- **The directory stays flat.** `docs/harness-contract.yml` freezes script paths,
  `install-harness.sh` manifests them, hooks are installed by absolute path, and
  the test suite references `scripts/*.sh` literally — so a `scripts/trace/`
  reshuffle is real cost for cosmetic benefit. A future `scripts/trace_tools/`
  Python package is the *only* sanctioned new subdirectory, and it adds a home
  without moving any frozen path.
- **No unified `harness` mono-CLI.** Single-purpose scripts invoked piecemeal (by
  agents, docs, and CI) are a feature: each is independently promptable and
  testable. A branded dispatch layer adds no capability. Skip it.

---

For the full analysis, line counts, and the staged Phase 0 / Phase 1 / Phase 2
plan behind these decisions, see
[docs/scripts-portfolio-review.md](scripts-portfolio-review.md).
