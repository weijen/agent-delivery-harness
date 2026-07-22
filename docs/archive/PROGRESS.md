> **RETIRED 2026-07-22.** This repo-wide journal duplicated git log, GitHub issues, and the
> per-issue trace; its update-before-PR obligation produced recurring late-stage failures with
> zero defect catches. Frozen here as history. The per-issue Action Log
> (`.copilot-tracking/issues/issue-NN/progress.md`, rendered from trace spans) is unaffected.

# Repo Progress — agent-delivery-harness

> **What this file is.** A single, repo-wide, running status log for the harness
> itself — the durable "what's done / what's in flight / what's next" that any
> fresh agent (or human) reads first to get its bearings before starting work.
> It is the pushed, tracked companion to:
> - the per-issue local Action Log at `.copilot-tracking/issues/issue-NN/progress.md`
>   (gitignored — **a different doc**; do not merge the two), and
> - `git log` + each issue's `feature_list.json` (the per-issue source of truth).
>
> Format is inspired by the `claude-progress.txt` pattern in Anthropic's
> ["Effective harnesses for long-running agents"](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents):
> a cumulative log that survives across context windows so progress continues
> instead of restarting.
>
> **How to update it.** When you close an issue, add/extend the relevant entry
> under *Delivered* (newest first), refresh *Snapshot* and *Next up*, and commit
> it on the issue branch. The `review-gate.sh status-doc` gate enforces that this
> file changed on the branch before a PR opens — **every change must update it,
> there is no opt-out** (it is what the next agent reads first).

_Last updated: 2026-07-22 (#312)_

---

## Snapshot

- **What this repo is:** a reusable, language-agnostic harness for issue-driven
  agent work — preflight, isolated per-issue worktrees, local progress state,
  quality gates, review sensors, and PR closeout, with declarative language
  support.
- **Delivered feature issues:** 35+ closed (see *Delivered* below).
- **Harness entrypoints (`scripts/`):** `init.sh`, `start-issue.sh`,
  `finish-issue.sh`, `create-pr.sh`, `merge-pr.sh`, `review-gate.sh`,
  `check-feature-list.sh`, `scaffold-language.sh`, `install-harness.sh`,
  `issue-lib.sh`.
- **Language profiles:** Python and Node.js shipped under `profiles/`; Go,
  Java, and Ruby are generator-supported via `scaffold-language.sh`.
- **Skills:** 9 under `.copilot/skills/` (code-review, create-pr, the
  four audit skills, security-audit, sync-docs, public-exposure-audit). The
  obsolete `general` skill was removed in #177 (its fallback role moved to the
  harness contract + AGENTS.md conventions).
- **Subagents:** planning, generator, code-review under
  `.copilot/agents/`.
- **Sensor suite:** 202 shell sensors (`tests/scripts/` + `tests/meta/`), run by
  the `harness-smoke.yml` CI workflow (which also installs `uv` and runs the
  Python profile gates — after the #272 export-leg removal these collect no
  tests and are handled honestly as a SKIP);
  a green run is a hard merge precondition (enforced by `merge-pr.sh`).
- **Per-feature evidence is enforced, not just counted (#144, #291):** the PR path
  (`review-gate.sh approve`/`check`, inherited by `create-pr.sh`) hard-blocks by
  default when a `passes:true` feature lacks either a matching `feature_start`
  span or a role-correct ordered `red_handback → impl_handback → green_handback`
  triple and has no governed teeth-proof waiver; the semantic spine comes
  directly from lifecycle and handback emitters.
- **Frozen contract:** `docs/harness-contract.yml` + `test_harness_contract.sh`
  guard the lifecycle against silent regression.
- **Trace schema contract:** `docs/evaluation/trace-schema.v1.json` +
  `test_trace_schema.sh` freeze the deep-trace span vocabulary (now with
  optional `span_id`/`parent_span_id` linkage fields).
- **Trace emitter:** `scripts/trace-lib.sh` (contract-registered owner script) —
  sourceable `trace_span` appends schema-v1 JSONL to
  `.copilot-tracking/issues/issue-NN/trace.jsonl` with auto-stamps, built-in
  JSON-safe redaction, reserved-key protection, and warn-only error paths;
  guarded by `test_trace_lib.sh`, `test_trace_lib_redaction.sh`,
  `test_trace_lib_isolation.sh`. All six lifecycle scripts now emit
  lifecycle/tool spans through it (frozen in the `trace_emission` contract
  section); agent-span conventions are #95.

## Next up

- **Trace-tool consolidation (#335) — in flight:** retired Copilot runtime
  reconstruction while retaining lifecycle, handback, review, and closeout
  gates; `test_semantic_spine_without_copilot_hook.sh` protects the boundary.
- **Conductor class-closure escalation (#298):** use consecutive same-class
  review verdicts to stop repeated point repairs and route a class-level fix,
  consistent with the generator failure taxonomy delivered by #317.
- **CI workflow hardening (#268) — in review:** third-party actions in
  `release.yml`, `python-ci.yml`, and `harness-smoke.yml` are SHA-pinned with
  readable version comments; non-release workflows now explicitly use
  `contents: read`, while the release job retains its scoped `contents: write`.
  Workflow-specific sensors cover the pinning and permission boundaries.
- **L0 evaluation workstream (#61–#64) — COMPLETE.** #61 (directory contract +
  manifest schema + validator), #63 (case-level TAP output for the 5 L0 sensors),
  #62 (local runner + scorecard + fail-closed redaction gate), and #64 (L0
  manifests + blocking CI gate) are all **delivered** (see below). L0 evals now
  run through the runner and block PRs in CI.
- **L1 evaluation workstream (open issues #66–#69):** skill
  description-discriminability proxy (#66), artifact schema evals (#67),
  code-review trigger dataset (#68), Azure Tier B runner + config/secret
  contract (#69). See
  [docs/evaluation/l1-solution/](evaluation/l1-solution/).
- **Deep-tracing remote-monitoring phase — #113 DELIVERED (see below):** the
  workbook + retention/PII spec + the two #112 carry-over hardenings landed.
  **Post-merge deploy step pending:** `terraform apply` the new
  `azurerm_application_insights_workbook` to the live sink (from the deploy
  worktree, `terraform -chdir=.../infra/terraform`, az on the personal sub).
  Core-workstream follow-ups still recorded: trace-gate promotion flag;
  trace-summary v1.x; VS Code Copilot token telemetry when a source appears.
- **Deep-trace tool-call + skill observability (#121 retired):** runtime
  reconstruction and its human Spike-Live capture task are retired. Deep tool,
  skill, model, and subagent analysis now reads Copilot native records through
  [docs/runtime-adapters/github-copilot.md](runtime-adapters/github-copilot.md).
- **In flight:** post-#113 hotfix — the workbook resource argument was
  `serialized_data` (wrong: fails `terraform validate`); corrected to
  `data_json`. The workbook is now DEPLOYED to the live sink (apply: 1 added,
  0 changed). `test_trace_dashboard_pack.sh` now grep-asserts `data_json` so
  CI (which has no Azure provider to run `terraform validate`) catches this
  schema class. Lesson: `terraform fmt` checks syntax, not provider schema —
  a fmt-clean `.tf` can still fail at apply.

---

## Delivered (newest first)

### Adopter-safe installer sensor profile (#312): delivery complete

- **Default installs are repository-neutral.** The installer consumes
  `tests/harness-dev-sensors.txt` and omits harness release, infrastructure,
  archive/eval-authoring, meta, and top-level documentation obligation sensors
  from adopter projects.
- **Upgrades clean old profile residue safely.** Byte-identical harness-dev
  sensors from earlier installs are pruned; modified copies survive with a diff
  unless `--update` explicitly removes them.
- **Full harness development remains available.** `--with-dev-sensors` installs
  the complete suite, while a clean-adopter acceptance sweep executes every
  default-installed core sensor and requires zero failures.

### Installer retired-asset pruning (#313): delivery complete

- **Managed deletions now propagate to adopters.** A SHA-256 tombstone ledger
  records retired harness assets and a history sensor prevents future managed
  deletions from landing without a tombstone.
- **Pruning is conservative by default.** Dry-run reports removals, `--write`
  deletes only files that still match their final upstream content, and
  modified retired files survive with a digest diff and non-zero result.
- **Destructive cleanup stays explicit.** `--update` may remove a modified
  retired file only after showing its digest diff; replacement directories are
  never recursively deleted.

### Archive dormant docs/evaluation content (#337): delivery complete

- **21 zero-runtime-reference evaluation docs archived.** Moved under
  `docs/archive/evaluation/` (statistical-methodology, dataset-governance,
  mutation-evals, judge-evaluation, and kin) with a tombstone pointing at
  epic #331; runtime-referenced files were left in place — `trace-schema.v1.json`
  and `cost-efficiency-evals.md` (kept in `docs/evaluation/` because
  `scripts/trace-report.sh` depends on them) and `product-quality-rubric.md`
  (kept because agent doctrine references it, not `trace-report.sh`) — plus
  all L0 assets and `docs/evaluation/l1-solution/`, along with the #333/#335
  transitional schemas pending those children landing.
- **Four archive-content/audit sensors retired** (they gated on now-archived
  prose) and **one dynamic archived-reference sensor added** that scans
  `scripts/`, `.copilot/`, and `AGENTS.md` for stale runtime/doctrine
  references still using the old `docs/evaluation/<moved-path>` locations and
  fails on a hit.
- **Human-approved #337-only sensed-tree metric:** net -15 lines with pure
  file moves counted zero; full shell sensor suite 223/223 green.

### installer runtime dependency closure (#311): delivery complete

- `install-harness.sh` now ships the eval, fixture, release, environment, and
  evaluation-document assets required by installed workflow consumers.

### closeout: final summaries and native Copilot economics (#329): delivery complete

- **Closeout now requires a fresh summary.** Before teardown,
  `finish-issue.sh` verifies the canonical trace reporter can regenerate
  `trace-summary.json`; failure leaves the worktree intact. The shared terminal
  trap refreshes it again after the `finish` span so final counts survive.
- **Native records supply honest per-issue economics.** Closeout window-joins
  `subagent.completed` and cumulative usage checkpoints from the active
  Copilot session, recording only complete in-window token/model/tool/duration
  aggregates and a bracketed, non-decreasing AIU delta. Missing or malformed
  data is omitted rather than rendered as zero, `unknown`, or `n/a`.
- **Two new mutation-backed sensors bring the shell suite to 221.**
  They cover missing/stale summary regeneration, mandatory failure behavior,
  multi-model window isolation, incomplete records, AIU rollback, absent native
  state, and full teardown survival.

### trace consistency: preserve pre-attribution fail spans (#330): delivery complete

- **Historical failures no longer invalidate old traces.**
  `check-trace-consistency.sh` downgrades missing failure class, finding
  fingerprint, and baseline state to warnings only when the span timestamp is
  provably earlier than PR #324's merge instant.
- **Current enforcement stays fail-closed.** Spans at or after the boundary,
  and spans with absent or malformed timestamps, retain the three violations.
  The boundary deliberately does not use the drifting `harness.version`.
- **A new mutation-proven sensor brings the shell suite to 219.**
  `test_trace_consistency_legacy_fail_span.sh` covers legacy, current, exact
  boundary, malformed timestamp, complete-field, and disabled-carve-out cases.

### create-pr: carry approval across content-preserving rebases (#310): delivery complete

- **Approval records a stable branch identity.** `review-gate.sh approve`
  keeps the approved HEAD on marker line 1 and writes a Git-native digest of
  the ordered stable patch-id stream on line 2. Ordinary checks remain
  compatible with legacy single-line markers. If the base is unavailable or
  the approved branch contains a merge commit, line 2 is blank so carry is
  ineligible rather than guessed.
- **Only an actual content-preserving default rebase can carry approval.**
  `create-pr.sh` passes the exact pre-rebase HEAD to the review gate after a
  successful rebase. Carry succeeds only when that SHA matches marker line 1
  and the merge-free post-rebase patch identity exactly matches marker line 2;
  the marker then advances to the new HEAD and a
  `review_gate_approve` span records `harness.review_gate_carry=patch-id`.
  The authoritative approval check still runs afterward.
- **Every other HEAD change remains fail-closed.** Changed post-rebase
  content, wrong SHAs, malformed or legacy identities, merge histories,
  `CREATE_PR_NO_REWRITE` merges, and reactive force-policy fallback merges
  cannot carry approval and continue to require a fresh review approval.
- **Two new red-first sensors bring the shell suite to 218.**
  `tests/scripts/test_review_gate_patch_id_store.sh` covers seven marker,
  portability, empty-branch, unavailable-base, and rebase-stability cases.
  `tests/scripts/test_create_pr_carry_approval.sh` covers eight positive,
  mutation, trace-consistency, malformed-state, merge-history, and
  non-rewriting-path cases.

### create-pr: non-rewriting sync path — force-with-lease is a preference, not a hard dependency (#326): delivery complete

- **`CREATE_PR_NO_REWRITE` explicit history-preserving sync mode.** When set,
  `create-pr.sh` skips rebase and force push entirely: it opens the PR from
  the current branch tip when it already cleanly targets `origin/main`, or
  merges `origin/main` into the branch (re-gating the new merge HEAD for
  approval) when a sync is needed, then does a plain push. Default rebase
  preference and behavior are unchanged when the flag is unset.
- **Reactive fallback when the remote itself rejects force-push.** A narrow
  classifier distinguishes a genuine force-push-policy rejection from any
  other push failure. On a policy rejection, the script restores the
  pre-rebase tip from a branch-scoped, script-owned ref (`refs/create-pr/presync/<branch>`)
  written immediately before the one place it runs `git rebase origin/main`
  — never git's shared, unnamespaced `ORIG_HEAD` — validates the remote's
  actual current tip is an ancestor of that owned restore point before any
  `git reset --hard`, merges `origin/main`, re-checks approval on the new
  merge HEAD, and plain-pushes once approved. It never issues a bare
  `--force` push and never swallows unrelated (auth/network/content) push
  failures, which remain hard, unswallowed errors with HEAD unmoved and no
  PR opened.
- **Push contract documented.** `docs/HARNESS.md`'s Review Gate section and
  `scripts/create-pr.sh`'s header now both state, in matching terms, that
  `--force-with-lease` applies only to the run's own single-writer feature
  branch and is never used against `main` or a shared branch, that
  `CREATE_PR_NO_REWRITE`/the reactive fallback make rebase a non-load-bearing
  preference, and that force is never issued bare.
- **Sensors, all red-first:** `tests/scripts/test_create_pr_no_rewrite.sh`
  (current-tip, merge-required, and conflict scenarios against real local git
  fixtures — failed pre-implementation against the unconditional-rebase
  script, passed after the `CREATE_PR_NO_REWRITE` branch landed);
  `tests/scripts/test_create_pr_force_reject_fallback.sh` (a real bare-origin
  pre-receive force-push-policy hook drives the rejection/restore/merge/
  re-approve/plain-push path and a genuine non-policy failure stays hard;
  strengthened mid-repair to prove the owned pre-sync ref — not `ORIG_HEAD` —
  is the sole cross-invocation restore point, failing red until the ref
  writer, remote-ancestor guard, and ORIG_HEAD removal were all in place);
  `tests/meta/test_create_pr_push_contract_docs.sh` (failed red against the
  unmodified docs/header for every missing contract statement, passed once
  the matching prose was added to both).

### Fix lifecycle scripts' --help side effects and require merge evidence (#328): delivery complete

- **`create-pr.sh` and `merge-pr.sh` `-h`/`--help` are now side-effect free.**
  Both scripts exit 0 on usage before sourcing `trace-lib.sh` or touching
  `gh`/`git`, instead of falling through into rebase, PR resolution, or merge
  logic.
- **`merge-pr.sh` re-verifies GitHub state before declaring success.** After
  `gh pr merge` returns zero, a new `merge_verify` step calls
  `gh pr view --json state,mergeCommit` and only stamps the pass span's
  `harness.merge_state`/`harness.merge_sha` (and prints "merged.") when
  GitHub independently confirms `state=MERGED` with a non-empty merge commit;
  otherwise it fails loudly at `harness.stage=merge_verify`.
- **Closeout rejects unevidenced merge claims while keeping the authoritative
  GitHub check.** `finish-lib.sh`'s merged-conclusion path still trusts
  `finish__merged_pr_exists` (GitHub's own merged-PR record) but now also
  blocks when a present, successful `pr_merge` span lacks
  `harness.merge_state=MERGED`/`harness.merge_sha`; issues with no `pr_merge`
  span at all remain unaffected (backward compatible).
- **Regression protection is executable.** Four red-first sensors cover
  `create-pr.sh` help side-effect freedom, `merge-pr.sh` help side-effect
  freedom, the `merge_verify` trace contract, and the closeout evidence gate.

### Generator stuck-triggered external research (#317): delivery complete

- **The second same-class generator failure stops point-fixing.** Generator
  handbacks reuse the closed failure-class taxonomy and record a separate
  disposition that routes knowledge gaps to research, complexity to
  decomposition, and known-flaky or polling work to an explicit exemption or
  override.
- **Research is bounded, auditable, and diagnosis-only.** Runtime-specific
  capability notes limit a class to one five-minute/one-document action,
  preserve validated URL plus one-line provenance through the trace and Action
  Log, and fail closed with `research-requested` when web access is unavailable.
- **Class fixes survive the current run and remain measurable.** Successful
  escalated repairs name an existing always-loaded repository rule and lesson;
  trace summaries and cross-run reports show canonical same-class counts, coverage,
  and the report-only target of at most two without fabricating historical
  zeros.

### Synchronize Copilot native-record guidance with versioned evidence (#319): delivery complete

- **Copilot token and cost claims are now version- and provenance-scoped.** The
  adapter distinguishes the CLI <=1.0.54 shutdown buckets, the observed
  1.0.72-1 cumulative nano-AIU checkpoint shape, and the community live-RPC
  alternative without presenting undocumented fields as a stable contract.
- **`copilot-log-review` now treats CLI records as first-class inputs.** Its
  Locate and Quantify stages cover `events.jsonl`, `session-store.db`, nested
  payloads, fractional timestamps, cumulative-checkpoint deduplication,
  malformed records, and the empirical nano-AIU to official AI Credits mapping.
- **Cross-surface review is explicit but honest.** A portable, fixture-executed
  enumeration recipe inventories VS Code and CLI records by UTC event-span
  overlap while keeping session-ID and OTel equivalences unverified unless
  independently proven.
- **Regression protection is executable.** Five new sensors cover permission
  setup, the token matrix, CLI cost recipes, cross-surface enumeration, and a
  typed fixture/recipe/claim manifest with exact row bijections and mutation
  teeth under macOS Bash 3.2.

### Make review failures attributable, stable, scoped, and actionable (#318): delivery complete

- **#318 makes review rejection state mechanically countable and safe to
  re-review.** Every FAIL now carries feature attribution, a closed failure
  class, stable finding identity, SARIF-style baseline state, and explicit
  review-event identity. Repair verdicts pin a canonical revised-feature scope
  while retaining whole-diff visibility. Only findings backed by reproduction
  evidence or a concrete fix consume the per-feature reject cap;
  non-actionable findings remain warnings, and historical traces retain honest
  compatibility. Five red-first integration and mutation sensors cover the
  cross-field contract and bring the shell sensor suite to 201.

### Finalize closeout records and honest delivery economics (#320): delivery complete

- **#320 makes `finish-issue.sh` leave a terminal, auditable record before
  teardown.** Closeout now writes a conflict-safe merged or explicitly abandoned
  conclusion with the observed review verdict, strips exact scaffold cruft, and
  hard-blocks unresolved placeholders. Delivery economics count logical review
  events rather than per-feature verdict spans and report both elapsed and active
  time, excluding complete gaps over 30 minutes. Four independent red-first
  sensors cover conclusion survival, cruft handling, review-event aggregation,
  and active-time boundaries, bringing the shell sensor suite to 196.

### Bound init-gate sensor runtime to fixtures (#315): delivery complete

- **#315 removes adopter-size work from `test_init_gates.sh`.** The real-root
  smoke now uses controlled tools and the existing fail-closed preflight path
  to assert surface detection without executing project gates. Python, Node,
  and Terraform gate routing runs against a tiny fixture with explicit command
  evidence, while docs-only and failed-gate coverage remain intact.

### Prevent retired trace-tools debris from recurring (#316): delivery complete

- **#316 removes the ignored bytecode debris and makes the retirement durable.**
  The export-leg deletion sensor now requires an explicit root-anchored
  `/scripts/trace_tools/` ignore rule in addition to proving the directory and
  its live importers are absent. This prevents generated artifacts from
  resurrecting the retired package as trackable repository content.

### Retire the runtime capture layer (Phase 1), keep the semantic spine (#305): delivery complete in PR #309

- **#305 retires the runtime capture layer that produced zero usable yield** (systemic
  dark runs under multi-issue concurrency, no token data ever) while keeping the
  **semantic spine** — the spans the harness scripts emit about themselves
  (`log-handback.sh` agent spans, lifecycle spans, the Action Log) and every check
  built on them (reject cap #302, provenance/dedup #304). Native Copilot records
  (the `copilot-log-review` skill, #306) are the replacement analysis path. Phase-2
  deletion of the capture code is out of scope, gated on one native-records-only L4
  on foundry with nothing missing. Four features, each red-first with a teeth-proof
  (net +2 sensors to 192): (1) **`dark_run` rescoped** — with capture retired, "no
  runtime tool spans" is normal, so `check-trace-consistency.sh` now emits
  `spine_incomplete` (a complete issue window missing the handback spine) instead of
  the runtime-span `dark_run`; #299/#300 traces pass; (2) **no hook seeding** —
  `start-issue.sh` no longer copies the `harness-trace.json` hook config into
  worktrees and drops the obsolete dark-run launch warning (the retired
  `local-hook-seeding` contract clause is removed too); (3) **capture deprecated**
  — the adapter doc + capability matrix mark tool/skill-span capture,
  interval/marker/binding attribution, token passthrough, and the OTel Path O join
  deprecated, naming `copilot-log-review` as the replacement; (4) **boundary
  documented** — `observability-and-trace-schema.md` authoritatively draws the kept
  (spine) vs retired (capture) line and states the Phase-2 gate. The end-of-issue
  review caught a sync-docs contradiction (the launch-topology/dark-run doctrine in
  `AGENTS.md`/`harness.instructions.md`/`observability-journey.md` still framed a
  non-root launch as a harmful dark run); the repair loop reconciled all of them.
  This is the first issue whose own delivery ran under the rescoped `spine_incomplete`
  check rather than the retired `dark_run`.

### copilot-log-review skill — workflow review from Copilot native records (#306): delivery complete in PR #308

- **#306 packages the workflow-review analysis (issue-65 cost surveys, live
  health checks) as a repeatable, report-only skill.** `copilot-log-review`
  reviews an issue run, a day's work, or an L4-style batch directly from GitHub
  Copilot's native records (transcripts, hooks log), joining offline against the
  harness lifecycle spans — no live capture, no hooks, no new span emission.
  Three features, each red-first with a teeth-proof (three new sensors bring the
  suite to 190): (1) **registration** — the `.copilot/skills/copilot-log-review/`
  skill skeleton with valid frontmatter, added to the `audit-sweep` `NON_AUDIT`
  list (it reads local session transcripts absent in scheduled CI, so it runs
  on-demand / per L4, not in the weekly code-audit sweep) with the
  `test_audit_sweep.sh` exclusion kept consistent; (2) **Quantify recipes** — jq
  recipes for session inventory and tool/time decomposition that pair
  `tool.execution_start`/`complete` by `toolCallId` (never `sort_by(.type)`,
  which inverts durations) and skip orphaned/incomplete calls, validated
  executable against a committed synthetic fixture; (3) **Locate/Qualify/Report**
  — workspace-hash resolution, `reasoningText` sampling, and a report following
  `_audit-conventions.md` under `logs/audit/`, with a report-only + privacy rule
  (never commit raw transcript excerpts) and macOS-verified paths. The
  end-of-issue review caught a MAJOR (recipes crashed on an orphaned tool call);
  the repair loop guarded both recipes and extended the fixture to cover it.

### Generator owns per-feature verification; single end-of-issue review (#303): delivery complete in PR #307

- **#303 moves independent code review from per-feature to one review at issue
  completion, with the generator owning per-feature verification.** This changes
  review *timing*, not review *independence* (the Haleon L4 evidence supports the
  independent adversarial eye, which is preserved). Five features, each red-first
  with a teeth-proof (five new sensors bring the suite to 187): (1) **Loop 2
  doctrine** — `harness.instructions.md` §3 no longer invokes
  `code-review-subagent` per feature; the one independent review runs at issue
  completion over the whole branch diff in `full` mode issuing **per-feature
  verdicts**, a `NEEDS_REVISION` routes back to the generator per feature, and the
  post-repair re-review runs in `repair` mode scoped to that feature; the
  3-rejection cap and red-first evidence rules are unchanged; (2) **generator
  self-check** — `generator-subagent.agent.md` gains a pre-handback self-check
  delivery checklist absorbing the product-quality rubric general checks #1–#5
  (correctness, readability, tests, error handling, security), framed as
  self-verification and distinct from the four blocking gates; (3) **reviewer
  contract** — `code-review-subagent.agent.md` (and one `AGENTS.md` row) now
  describe reviewing the completed issue diff once with per-feature verdicts and
  repair-mode re-review, boundary and skill battery preserved; (4)
  **verdict-missing detection** — `check-trace-consistency.sh` emits
  `review_verdict_missing <fid>` when the review/approve phase is active (a
  `review_gate_approve` span present or `REVIEW_GATE_APPROVE_PHASE=1`) and a
  `passes:true` feature has no `review_verdict` span, silent mid-issue; (5)
  **verdict-missing gate** — `review-gate.sh` adds `review_verdict_gate` that
  hard-blocks `approve` (before the marker) and `check` on that finding. This
  issue's own delivery run dogfoods the new model: one end-of-issue review issued
  five per-feature verdicts before approval.

### Review provenance + irreversibility-scoped pre-PR gate (#299): delivery complete in PR #304

- **#299 adds the measurement/enforcement layer on top of #300 and removes a
  structural double-run from the pre-PR gate.** Four features, each red-first
  with a teeth-proof (three new sensors bring the suite to 182): (1)
  **review-verdict provenance** — `review_verdict` spans now carry
  `harness.review_mode` (a `TRACE_REVIEW_MODE` env passthrough, closed enum
  `full|concise|repair`, omit+warn otherwise) and an auto-captured
  `harness.reviewed_sha` (`git rev-parse HEAD` at emit time), both scoped to
  `review_verdict` spans; (2) **duplicate-full-review detection** —
  `check-trace-consistency.sh` warns (`duplicate_full_review`, warn-only, never
  wired into `review-gate.sh`) when two `full`-mode reviews share a
  `(feature_id, reviewed_sha)` pair; (3) **irreversibility-scoped §6 list** — the
  standalone pre-PR sensor list shrinks to the irreversible-on-push checks
  (`code-review-subagent (full)`, `security-audit`, `public-exposure-audit`);
  the five quality skills keep diff-scoped coverage via the full review's
  embedded checks #6–#11 and whole-repo coverage via the `audit-sweep` cadence
  (weekly/per release, → scheduled CI when #256 unblocks); (4) **reviewer
  instruction-files discipline** — a warn when a feature's handbacks carry
  `harness.instruction_files` but its `review_verdict` span does not, plus the
  conductor doctrine to set `TRACE_INSTRUCTION_FILES` on reviewer verdicts.

### Repair-loop context control (#300): delivery complete in PR #302

- **#300 shrinks each repair-loop round and hard-stops runaway review loops.**
  Building on the log survey behind #298/#299, it delivers the compliance +
  observability gap the owner scoped: (1) `log-handback.sh` records which
  instruction files the conductor injected into each handback via a new
  `TRACE_INSTRUCTION_FILES` passthrough (`harness.instruction_files` span,
  omit-never-fake, export-excluded); (2) a distinct `repair` review profile for
  the `code-review-subagent` that skips the whole-diff skill battery (#6–#11,
  including `public-exposure-audit`) mid-loop and defers it to the pre-PR `full`
  review; and (3) a deterministic, per-feature review-rejection cap —
  `check-trace-consistency.sh` flags `review_reject_cap_exceeded` at the 3rd
  `review_verdict`/`fail` for a feature, and `review-gate.sh` hard-blocks by
  default (approve + check) so the issue stops and hands back to the human,
  documented in the Loop 2 doctrine. Four features, each red-first with a
  teeth-proof; three new sensors bring the suite to 179.

### Customization frontmatter lint (#65): delivery complete in PR #301

- **#65 replaces duplicated skill and agent fence checks with one shared,
  dependency-free structural validator.** Skills require a folder-matching
  lowercase alphanumeric-or-hyphen name of 1–64 characters and a nonempty
  description of at most 1,024 characters. Agents retain their distinct
  contract: `name` is optional, while frontmatter fences, tab-free indentation,
  and the description limits remain enforced. Stable diagnostics cover all
  approved failure reasons, including unsupported block-scalar descriptions,
  with generated fixture coverage for boundaries and precedence. Local smoke
  and GitHub Actions now invoke the same validator entrypoint, and a dedicated
  wiring sensor prevents either consumer from restoring the obsolete parser.

### Generator-role workflow and experiment instrumentation (#296): delivery complete
- **#296 completes all four workflow and instrumentation features.** The active
  feature cycle now uses one `generator-subagent` for RED, implementation,
  GREEN, teeth proof, and pass-state updates. The reviewer owns test-only
  adversarial coverage and routes production defects back to the generator.
  Trace evidence accepts complete generator triples while preserving historical
  role traces and rejecting mixed-role triples. Trace summaries and scorecards
  expose optional role-neutral per-feature elapsed, review-fail, blocked-GREEN,
  and coverage measurements derived from observed lifecycle spans. This delivery
  does not adopt the generator model. The final adoption decision remains
  deferred until later measured evidence provides at least 30 paired
  observations per arm, no critical false negatives, review detection
  non-inferiority within 10 percentage points on controlled adversarial
  fixtures, and a median elapsed reduction of at least 20% under the documented
  confidence-interval criterion. Blocked GREEN remains diagnostic only, and an
  underpowered sample yields `insufficient evidence`.

### Installed runtime closure (#294): make adopted harnesses self-sufficient
- **#294 — `install-harness.sh --write` omitted runtime dependencies required by the trace and hook sensors it copied, so a fresh adopter failed immediately and stamped spans as `harness.version: 0.0.0-dev`.** One red-first feature closes the installed-runtime boundary: `HARNESS_ASSETS` now includes `VERSION`, the trace/log/summary/scorecard schemas, the observability contract required by the adapter-doc sensor, and `docs/runtime-adapters/` recursively. The dedicated `tests/meta/test_installed_harness_runtime.sh` installs into an isolated temporary target, verifies every required asset byte-for-byte, parses the schemas and hook examples, checks installer help and onboarding inventory, and runs six curated version/trace/schema/adapter/hook sensors from the installed target. Existing dry-run, write, idempotency, no-clobber, and update behavior remains covered by `test_install_harness.sh`; the optional `--with-hooks` proposal is deferred to a separate issue.

### Feature-start enforcement (#291): preserve the per-feature selection boundary
- **#291 — `feature_start` was documented but not enforced, so feature execution could drift directly into RED/implementation without a traceable selection-time boundary.** Three sensor-owned features close the gap: (1) `checker-feature-start-missing` makes `check-trace-consistency.sh` emit `feature_start_missing <fid>` for every unwaived `passes:true` feature without a matching agent `feature_start` span; (2) `gate-blocks-feature-start-missing` promotes that finding through the existing PR evidence gate so approve, check, and create-pr reject it while standalone trace rollout remains warn-only by default; and (3) `contract-and-doctrine-feature-start` freezes the token on the existing gate and documents the shared canonical `teeth_proof_waiver` / deprecated `red_first_waiver` precedence. The dedicated checker and PR-path sensors cover matching/missing/wrong-feature spans, both waiver forms, malformed-canonical shadowing, all three closeout paths, and standalone trace behavior. Full 170-sensor suite + shellcheck (CI glob) + L0 green.

### Action Log survival (#290): migrate the authoritative worktree record before teardown
- **#290 — post-hoc trace consistency was blind after closeout because `log-handback.sh` wrote the Action Log only to the worktree `progress.md`, which `git worktree remove` deleted.** The #285 economics dual-stamp left a surviving but hollow main-root file, so the checker compared real agent spans against an empty Action Log and reported false `span_without_log` findings. **Two sensor-owned features:** (1) `finish-migrate-progress-md-survives-teardown` — `finish-issue.sh` now runs `progress_migrate → economics_stamp → worktree_remove`; `best_effort_progress_migrate` copies the authoritative worktree file verbatim into the main-checkout tracking dir through a validated, non-symlink path, uses temp-copy + atomic rename so failed copies cannot corrupt an existing survivor, and warns/skips without blocking teardown when the source/path/atomic tools are unavailable. Economics markdown stamping runs only after confirmed migration, eliminating both worktree dual-writing and hollow-file synthesis. The 14-leg `tests/scripts/test_finish_issue_progress_migration.sh` drives real start/handback/finish/checker flows and pins byte-identical authority, ordering, idempotent pre-teardown retries, gone-worktree skips, existing-main replacement, copy/tool failures, leaf/ancestor symlink safety, stale-file preservation, single-write `log-handback.sh`, and post-teardown `check-trace-consistency.sh <N>` success. (2) `docs-progress-md-survives-teardown` — `docs/HARNESS.md` Local Tracking documents worktree authority, main-root migration/survival, post-hoc consistency, and the shared `trace.jsonl` rationale; `tests/meta/test_progress_survival_docs.sh` structurally guards the vocabulary, relationships, and executable production stage order without sentence pinning. Full 168-sensor suite + shellcheck (CI glob) + L0 green.

### batch-review residue (#285): economics-stamp survival, generator-supported README, export-leg residue, sensor blind spots
- **#285 — an L4 batch-review left six residue items where a sensor or artifact looked delivered but wasn't.** Each was reproduced before fixing. **Six features, all red-first (`red_handback → impl_handback → green_handback`):** (1) `economics-stamp-survives-teardown` — `best_effort_economics_stamp` in `scripts/finish-lib.sh` stamped the delivery-economics block only into the *worktree* `progress.md`, which `git worktree remove` then deleted; it now also stamps into the surviving **main-checkout** `.copilot-tracking/issues/issue-NN/progress.md` (seeding a minimal header if absent), and `tests/scripts/test_finish_issue_economics_stamp.sh` asserts the block survives *after* teardown. (2) `profiles-readme-generator-supported` — `profiles/README.md` still framed Go/Ruby/Java as shipped `*.profile.sh` descriptors (removed in #274); rewritten as generator-supported (scaffolded on demand), and `tests/scripts/test_docs_shipped_profiles.sh` widened to enforce it. (3) `remove-dead-export-residue` — the consumerless `TRACE_SECRET_SHAPE_RE` constant (`scripts/trace-lib.sh`) and production-dead `load_env_allowlist` (`scripts/finish-lib.sh`, plus its `test_finish_env_allowlist.sh`) — both orphaned by the #272 export-leg deletion — removed; `tests/meta/test_no_deleted_export_refs.sh` sweep widened to `scripts/`. (4) `revision-loops-missing-file-guard` — `tests/meta/test_revision_loops.sh` `if [ -f file ]` guards had no else branch, so deleting a guarded doc/agent file silently passed; each guard gained an else-fail branch (proven by a negative fixture). (5) `waiver-precedence-fixtures` — `tests/scripts/test_trace_red_first_evidence.sh` gained both-keys fixtures proving `teeth_proof_waiver` wins by key presence — a malformed `teeth_proof_waiver` shadows a *valid* legacy `red_first_waiver` and VIOLATES (the trap), and the self-contradicting header was corrected. (6) `review-doctrine-artifact-survival` — `.copilot/agents/code-review-subagent.agent.md` Verdict-3 test-adequacy gains a checklist point: for a file/record deliverable, verify the artifact SURVIVES the full lifecycle (worktree teardown), not merely that it is emitted; guarded by new `tests/meta/test_review_artifact_survival.sh`. Full 166-sensor suite + shellcheck (CI glob) + L0 green.

### Loop 3 plan-correction escape hatch (#88): make return-to-planning explicit + fail-closed
- **#88 — the harness documented Loop 1 (implementation ↔ test) and Loop 2 (review → implementation) but left the "the plan itself is wrong" recovery implicit.** `Plan first` handbacks, wrong-declared-sensor handbacks, and review scope/planning routing all existed, but the return-to-planning step was easy to forget, and nothing stopped a falsified feature from staying `passes:true`. **Two features, each red-first (`red_handback → impl_handback → green_handback`):** (1) `loop3-plan-correction-doc` — a lightweight **Loop 3 (plan correction)** subsection in `harness.instructions.md` §3 (triggers: `Plan first`, wrong declared sensor, a review scope/planning decision, or two failed repairs revealing a bad plan assumption; conductor action: record the blocker in the Action Log, pause feature work, update the plan or re-invoke `planning-subagent`, reset affected features to `passes:false` via the existing `blocked_on` field, re-run the human-input gate only on scope/breakdown/mapping/contract change) plus a mirrored paragraph in `docs/HARNESS.md`; Loop 1 and Loop 2 stay the default path and no new roles/scripts/state files are added — guarded by an extended `tests/meta/test_revision_loops.sh` Loop 3 closed-vocabulary assertion. (2) `blocked-passes-mutual-exclusion-sensor` — a fail-closed rule in `scripts/check-feature-list.sh`: a feature with a non-empty `blocked_on` **and** `passes:true` is now a hard structural failure (a replanned/blocked feature can never also be "green"); empty/absent/null `blocked_on` and `blocked_on`+`passes:false` are unaffected. New sensor `tests/scripts/test_feature_list_blocked_passes.sh` (4 cases). Full 166-sensor suite + shellcheck (CI glob) + L0 green.

### finish-issue worktree-error surfacing (#91): show git's real error, not a generic guess
- **#91 — `scripts/finish-issue.sh` suppressed `git worktree remove`'s stderr (`2>/dev/null`) and printed a generic `✗ Worktree has uncommitted changes (or is locked).`** — a resuming operator could not tell whether the worktree was dirty, locked, or in some other failure state, making recovery guesswork. **One feature, red-first (`red_handback → impl_handback → green_handback`):** `surface-worktree-remove-error` — the `worktree_remove` stage now captures `wt_remove_err="$(git worktree remove … 2>&1)"` and, on failure, prints `✗ Could not remove the worktree at <dir>:` followed by git's OWN error text (indented) and the unchanged commit/stash-or-`FORCE=1` remediation hint, then `exit 1`. `FORCE=1` behavior is untouched (discards the work, removes the worktree). Sensor `tests/scripts/test_finish_issue_worktree_error.sh` drives the real `finish-issue.sh` in a temp repo + issue worktree carrying a non-ignored untracked file: (1) no-`FORCE` → exit 1 with git's `contains modified or untracked files` text + the `FORCE=1` hint + the worktree surviving; (2) `FORCE=1` → removed, exit 0. Full 165-sensor suite + shellcheck (CI glob) + L0 green.

### create-pr loud-failure (#90): never report a failed PR closeout as success
- **#90 — `scripts/create-pr.sh` reported a successful closeout on a *failed* one.** `gh pr create`'s exit status was unchecked and, more critically, when the PR number could not be resolved afterward (`gh pr view` yielding empty) the script printed `✓ PR #  is open.` with a **blank number and exit 0** — the harness declaring victory on a broken closeout. **One feature, red-first (`red_handback → impl_handback → green_handback`):** `fail-loud-on-pr-create-failure` — the `pr_create` stage now (a) wraps `gh pr create "$@"` in `|| { … exit 1; }` so a non-zero create prints a clear `✗ gh pr create failed` error + re-run hint and never reaches the success line, and (b) guards the resolved `pr_number` — an empty value prints `✗ PR opened but its number could not be resolved.` + "check GitHub manually" and exits non-zero. The idempotent already-exists path (first `gh pr view` returns a number → re-sync + push, no create) is untouched. Sensor `tests/scripts/test_create_pr_failure.sh` drives the real `create-pr.sh` against a fake `gh` through the review-gate approval: (a) `GH_CREATE_FAIL=1` → non-zero exit, `✗` error, no `is open`; (b) `GH_VIEW_BLANK=1` → non-zero exit with a manual-check hint. **Knock-on:** three existing review-gate sensors (`test_review_gate.sh`, `test_review_gate_status_doc.sh`, `test_review_gate_ci_coverage.sh`) carried fake `gh` shims whose `pr view` returned nothing even after `pr create` (modeling the old buggy tolerance); they were updated to return a PR number once the PR exists, matching real `gh`. Full 164-sensor suite + shellcheck (CI glob) + L0 green.

### profile demotion (#274): ship python+node, demote go/java/ruby to generator-supported
- **#274 — the harness shipped five language profiles (`profiles/{python,go,node,java,ruby}.profile.sh`) but only Python and Node were exercised end-to-end; go/java/ruby were dead weight `install-harness.sh` copies verbatim into every adopter, and their per-language tests pinned surfaces no live pipeline runs.** An L4 outcome analysis demoted them to **generator-supported**: the `scaffold-language.sh` generator still carries their full metadata (regenerate any of them with `./scripts/scaffold-language.sh <lang> --write`), but the harness ships only what it verifies. **Three features, all red-first (each carries an ordered `red_handback → impl_handback → green_handback` triple):** (1) `remove-demoted-profiles` — `git rm` of `profiles/{go,java,ruby}.profile.sh`; `scripts/init.sh`'s go/ruby/java gate branches now guard on descriptor-presence (`[ -f profiles/<lang>.profile.sh ]`) so a repo carrying `go.mod`/`Gemfile`/`pom.xml` **warns + points at the generator instead of crashing** on the deleted source, and a scaffolded-back profile is auto-detected again (generator-supported contract preserved); sensor `tests/scripts/test_demoted_profiles_scaffoldable.sh` asserts the descriptors are absent, python+node remain, the generator regenerates each with a valid interface, and init.sh degrades gracefully. (2) `tests-updated` — `git rm` of `test_{go,java,ruby}_profile.sh`, the multi-surface `test_init_gates.sh` fixture reduced to python+node+terraform+docs, and the `test_init_preflight.sh`/`test_review_gate_ci_coverage.sh` cases that pinned a demoted `go.mod` surface switched to the shipped `node` (`package.json`) surface; guard sensor `tests/scripts/test_demoted_profile_tests_absent.sh`. (3) `docs-shipped-vs-generator` — README, `docs/HARNESS.md`, `docs/multi-language-profiles.md`, `docs/getting-started.md`, and AGENTS.md reframed to "**ships** Python + Node; Go/Java/Ruby are **generator-supported** via `scaffold-language.sh`"; sensor `tests/scripts/test_docs_shipped_profiles.sh` rejects five-language "shipped" claims. **Deviation from the issue's "init.sh out of scope":** init.sh hard-sourced the deleted descriptors and would exit 1 on a go/ruby/java surface, so the descriptor-presence guard was the minimal change needed to keep the generator-supported contract truthful. Net 0 sensors (3 deleted, 3 added) → 163-sensor suite + shellcheck (CI glob) + L0 green.

### meta-test triage (#273): keep structural, convert doctrine-critical, delete phrase-pinning
- **#273 — `tests/meta/` had accreted phrase-pinning tests that grep prose no script parses, so their only failure mode was "someone rephrased a sentence" — Goodhart drift the batch's ethos rejects.** An L4 outcome analysis triaged all 47 meta-tests (plus 5 named `tests/scripts/*_docs.sh` siblings) against a **deletion criterion**: a meta-test earns its keep only if it validates machine-parsed structure or cross-file consistency. **Four features, all red-first (each carries an ordered `red_handback → impl_handback → green_handback` triple):** (1) `triage-record` — created `docs/evaluation/meta-test-triage.md`, an auditable KEEP/CONVERT/DELETE verdict table for all 52 candidates with the rubric legend and an honest note that the structural KEEP floor (~1,700 lines) makes the issue's "<1,500 lines" target unreachable; sensor `tests/scripts/test_meta_triage_record.sh` (≥40 verdict rows, legend, 4 buckets). (2) `deletions-executed` — `git rm` of 10 phrase-pinning `tests/meta/` files + 5 `tests/scripts/*_docs.sh` siblings, and scrubbed the R4 block in `test_runtime_adapters_docs.sh` that invoked a deleted sensor; guard sensor `tests/scripts/test_deleted_meta_tests_absent.sh` (files absent + no orphaned refs). (3) `conversions-executed` — rewrote 5 doctrine-critical tests (`test_role_separation`, `test_revision_loops`, `test_agent_span_doctrine`, `test_blocking_criteria`, `test_impl_usefulness_grading`) to assert the guarded section anchor (`^#` heading) + closed vocabulary instead of sentence fragments, so a title change still fails but a reword does not; sensor `tests/scripts/test_converted_meta_structural.sh` + a behavioral mutation check. (4) `rubric-doctrine` — recorded the KEEP/CONVERT/DELETE rubric + deletion criterion in `.copilot/instructions/bash.instructions.md` so new meta-tests are born structural; sensor `tests/scripts/test_meta_test_rubric_doctrine.sh`. Net −11 sensors (15 deleted, 4 added). Full 163-sensor suite + shellcheck (CI glob) + L0 green.

### tracing export-leg deletion (#272): remove the cloud export leg + trace-reconstruct (L4 deletion review)
- **#272 — the cloud trace/log export leg had no in-loop consumer.** An L4 deletion review (48-issue / 181-feature adopting project + a consumer audit) found no `trace.jsonl` survived in the adopter, the export leg's only reader was an App Insights workbook nobody consulted, `trace-reconstruct.sh` output was read by nothing, and 77% of test lines exercised tracing/export/hook code — dead weight `install-harness.sh` copies verbatim into every future adopter. Deletion criterion: **a trace component lives only if its output is read by an in-loop gate or a recurring human decision.** **Four features, all red-first (each carries an ordered `red_handback → impl_handback → green_handback` triple):** (1) `remove-export-scripts-and-callsites` — deleted `trace-export.sh`, `log-export.sh`, `gen-export-env.sh`, `sanitize-trace.sh`, `trace-reconstruct.sh`, and the whole `scripts/trace_tools/` Python package; stripped the 3 best-effort export/log-export/reconstruct helpers from `finish-lib.sh`, their 3 stages from `finish-issue.sh`, the mid-issue log-export step from `create-pr.sh`, and the cloud-export env block from `.env.example` (local `COPILOT_OTEL_FILE_EXPORTER_PATH` + generic `load_env_allowlist` kept); sensor `tests/scripts/test_export_leg_removed.sh`. (2) `contract-and-version` — removed the `trace-export` `scripts`/`lifecycle` entries and `TRACE_EXPORT_OTLP`/`_HTTP` `env_flags` from `docs/harness-contract.yml` and the export/reconstruct clauses from `finish-lib`'s role (contract-TDD: `tests/scripts/test_harness_contract.sh` edited first); MINOR bump lands via the `feat(#272)` PSR release. (3) `delete-orphaned-tests` — removed ~29 orphaned `test_trace_export_*`/`test_log_export_*`/reconstruct/sanitize tests + the meta allowlist pair, and scrubbed deleted-script references from surviving tests; guard sensor `tests/meta/test_no_deleted_export_refs.sh`. (4) `docs-and-infra-sweep` — deleted the App Insights workbook Terraform (`workbook.tf` + `harness-quality.workbook.json`, dated decommission note kept) and reframed the HARNESS / otlp-azure-monitor / observability / dashboards / dataset-governance / failure-review / telemetry-retention docs to "decommissioned by #272" **while retaining the trace schema + OTel attribute-name mapping as the future exit ramp**; a knock-on of removing the only Python package — `pytest` now collects 0 tests (exit 5) and `mypy` finds no `.py` (exit 2) — is handled honestly as a SKIP in the Python profile gate, `harness-smoke` CI, and `pyproject.toml`; sensor `tests/scripts/test_export_docs_removed.sh`. **KEEP (out of scope):** `trace-lib.sh`, both runtime hooks, `validate-trace.sh`, `check-trace-consistency.sh`, `log-handback.sh`, `trace-report.sh`/`trace-report.sh --all`, and the trace/log schemas. Full 173-sensor suite + shellcheck (CI glob) + L0 green.

### harness-hardening (#270): dedup issue-resolution, JSON-escape scaffolded titles, full-parity degraded redaction
- **#270 — three latent correctness gaps in the harness plumbing: `review-gate.sh` carried three byte-drifting copies of the issue-number resolution logic (TRACE_ISSUE → feature branch → worktree basename) across `trace_gate`/`log_completeness_gate`/`red_first_evidence_gate`, so a fix to one could silently skip the others; `start-issue.sh` interpolated the raw GitHub issue title straight into the scaffolded `feature_list.json`, so a title with a quote/backslash/newline produced invalid JSON; and `log-handback.sh`'s degraded (no-trace-lib) redaction fallback masked only two GitHub-token shapes, so an Action Log line written in a trace-lib-less checkout could leak AWS/Azure/OpenAI/JWT/SAS secret shapes that the real `trace_redact` would have caught.** All three fixed red-first (each feature carries an ordered `red_handback → impl_handback → green_handback` triple). **Three features:** (1) `review-gate-resolve-issue-helper` — the three duplicate blocks collapse into one `resolve_issue_number()` helper (same TRACE_ISSUE → branch `issue-NN`/`issue/NN` → worktree-basename precedence, skip-on-unresolved preserved); sensor `tests/scripts/test_review_gate_issue_resolution.sh` asserts structurally that exactly one resolution implementation remains and behaviorally covers all five resolution paths. (2) `start-issue-title-json-escape` — a `json_string()` helper (jq-preferred, pure-bash fallback) escapes the fetched title before it is written as `"title": <escaped>,`; sensor `tests/scripts/test_start_issue_title_escape.sh` drives a fake `gh` returning a quote/backslash/newline-laden title and asserts the scaffolded JSON parses and round-trips. (3) `log-handback-degraded-redaction` — the degraded `redact_line()` fallback now runs the **identical** full `trace_redact` sed program (byte-copied from `trace-lib.sh`), so the Action Log never leaks a shape the span filter would have masked; parity sensor `tests/scripts/test_log_handback_redaction_parity.sh` asserts the degraded bullet is byte-for-byte equal to `trace_redact`'s output over the full secret battery and that no raw secret survives. Full 204-sensor suite + shellcheck (CI glob) + L0 green.

### docs-sync (#269): synchronize installer/CI docs with the shipped harness + retire the stale health-check
- **#269 — three docs had drifted from the shipped harness: `getting-started.md` listed the installer's copied assets but omitted `.copilot/skills/` and `.copilot/prompts/`; the README + AGENTS `harness-smoke` summaries described only the shell sensor suite, silently dropping the `uv`/Python-profile-gate/L0 steps the workflow now runs; and `docs/copilot-health-check.md` (a 2026-07-08 point-in-time report) read as live state.** Docs-only, delivered red-first (each feature carries an ordered `red_handback → impl_handback → green_handback` triple with a mutation `teeth_proof`). **Three features:** (1) `getting-started-installer-assets` — `docs/getting-started.md` now names `.copilot/skills/` and `.copilot/prompts/` in the installer asset list; drift-guard sensor `tests/meta/test_docs_installer_assets_sync.sh` extracts the `.copilot/*` entries from `install-harness.sh`'s `HARNESS_ASSETS` array and asserts each is documented, so a future asset addition without a doc update fails. (2) `readme-agents-smoke-coverage` — the README and AGENTS `harness-smoke` paragraphs now name the `uv` setup/sync, the Python profile gates (`ruff format --check`, `ruff check`, `mypy`, `pytest`), and the L0 suite gate alongside the shell sensor suite; sensor `tests/meta/test_docs_smoke_coverage_sync.sh` flattens each paragraph and asserts all three token classes appear in both docs (line-wrap-tolerant), mutation-verified. (3) `health-check-superseded` — `docs/copilot-health-check.md` gains a **superseded / historical-snapshot** banner at the top (dated, linking `PROGRESS.md`/`HARNESS.md` + the #178–#184 remediation) while retaining its original `## Overall verdict` table and rows verbatim; sensor `tests/meta/test_docs_health_check_superseded.sh` asserts both the banner and the retained verdict rows. Full 201-sensor suite + shellcheck (CI glob) + L0 green.

### harness-economics (#267): auto-stamp trace-derived delivery economics at closeout (omit-never-fake)
- **#267 — the harness measured no delivery cost: an issue closed with zero record of how long it took, how many tokens/review-rounds/deviations it burned, or how many features actually passed with teeth. "Measured cost" was aspiration, not an artifact.** `finish-issue.sh` now auto-derives a **delivery economics** summary from the issue trace + `feature_list.json` and records it two ways — an operator-facing markdown block and a machine-readable span — under a strict **omit-never-fake / null-never-0** rule (an unmeasured metric renders `n/a` / is omitted, never a fabricated `0`). **Four features, all red-first (each carries an ordered `red_handback → impl_handback → green_handback` triple):** (1) `economics-summary-compute` — `scripts/finish-lib.sh` gains the PURE `compute_delivery_economics(trace, feature_list)` renderer: wall-clock span (first→last timestamp, fractional-second normalized like `trace-report.sh`), token totals **summed only from `model` spans carrying `gen_ai.usage.*`** with run coverage (`n/a` when none — never zero-token fabrication), review rounds, deviations, and feature counts (passes:true + teeth-proof); jq-missing/empty/parse-fail all fall through to `n/a`; sensor `tests/scripts/test_delivery_economics_compute.sh`. (2) `economics-stamp` — `economics_stamp_into()` (awk marker-region, idempotent between `<!-- delivery-economics:start/end -->`) + `best_effort_economics_stamp()` wrapper, wired into `finish-issue.sh` at `TRACE_STAGE=economics_stamp` **before** `worktree_remove` (so the worktree `progress.md` is still present) and always advisory (returns 0); sensor `tests/scripts/test_finish_issue_economics_stamp.sh`. (3) `economics-span` — the same helper appends exactly one `finish-issue.economics` **tool span** with typed numeric aggregates (`gen_ai.usage.input_tokens`/`output_tokens` sums, `harness.economics.token_runs`/`token_runs_total` coverage, `review_rounds`, `deviations`, `features_total`/`features_passing`/`teeth_proof`, `wall_clock_ms`); a new `harness.economics.` **numeric-key prefix** is registered across the single source (`trace-schema.v1.json` `.numeric_key_prefixes`, `validate-trace.sh`, `trace-lib.sh`, pinned in `test_trace_schema.sh`, drift guard taught to strip `harness.*` prefix stems); `required_by_span.model` relaxed to `gen_ai.request.model` only (usage is present **only when a runtime adapter reports it** — the token-run vs total distinction requires usage-less model spans to be valid) with the two usage keys documented as `optional_fields`; omit-never-fake proven by the no-tokens fixture asserting the usage keys are **absent** (not `0`); sensor `tests/scripts/test_economics_span.sh`. (4) `economics-docs` — `docs/HARNESS.md` documents the block + its honesty rule in Local Tracking and the span in Trace emission, cross-linking **#163** as the Copilot token-acquisition prerequisite for non-`n/a` token rows; mutation-verified sensor `tests/meta/test_docs_harness_economics.sh`. Full 198-sensor suite + shellcheck (CI glob) + L0 green.

### harness-honesty (#266): log-completeness gate — refuse closeout on unfilled Action Log placeholders
- **#266 — the harness could close an issue while its per-issue Action Log (`progress.md`) still carried unfilled placeholder stubs (`Recorded on completion below`, `TBD`, `TODO(fill …`), so "honest logs" were procedural hope, not an enforced outcome.** A new log-completeness gate scans the live Action Log and, like the trace gate, warns by default but hard-blocks under a promotion flag. **Four features, all red-first (each carries an ordered `red_handback → impl_handback → green_handback` triple with `red_first` teeth_proof):** (1) `log-completeness-checker` — `scripts/review-gate.sh` gains `log_completeness_gate()` + a `log-completeness` subcommand: it resolves the issue (TRACE_ISSUE / feature branch / worktree basename), `grep -nF`-scans the progress.md for the three placeholder signatures (file:line findings, deduped), is warn-only by default and hard-fails under `REQUIRE_LOG_COMPLETE=1`, and gracefully skips an unresolved issue or missing log; sensor `tests/scripts/test_log_completeness_gate.sh`. (2) `finish-issue-log-gate-wiring` — `finish-lib.sh` gains `finish_log_completeness_gate()` mirroring `finish_trace_gate` (missing review-gate.sh degrades to warn-skip), wired into `finish-issue.sh` **before** `worktree_remove` so a blocked finish leaves the worktree intact, and folded into `review-gate.sh check` so placeholders also surface pre-PR; sensor `tests/scripts/test_finish_issue_log_gate.sh` (real start-issue worktree fixture, both modes incl. the worktree-intact block). (3) `log-completeness-paths` — a single-source scan list: default is the issue progress.md, `LOG_COMPLETENESS_PATHS` (whitespace-separated `NN` templates) replaces it so adopting projects can point at their own persistent-log layout; nonexistent declared paths are skipped silently; sensor `tests/scripts/test_log_completeness_paths.sh`. (4) `log-completeness-docs-trace` — the gate emits exactly one `review-gate.log-completeness` tool span per **scanned** run carrying numeric `harness.finding_count` (0 emitted on a clean scanned log — omit-never-fake; **no** span when nothing was scanned, mirroring `trace_gate`), with `harness.finding_count` registered across all three single-source numeric-key mirrors (`trace-schema.v1.json` `.numeric_keys`, `validate-trace.sh`, `trace-lib.sh`; drift + key-coverage sensors kept green, `test_trace_schema.sh` bumped 6→7 keys); `docs/HARNESS.md` documents the gate, `REQUIRE_LOG_COMPLETE`, and `LOG_COMPLETENESS_PATHS`; sensor `tests/scripts/test_log_completeness_trace.sh`. Full 194-sensor suite + shellcheck (CI glob) green.

### review-quality (#265): execute-before-CRITICAL rule + known-false-positive registry (PEP 758)
- **#265 — in a real adopting project's 48-issue review history, `code-review-subagent` raised the *same* false-positive CRITICAL three times: it claimed `except A, B:` (unparenthesized multi-exception, PEP 758, valid on Python 3.14) was a Py2 SyntaxError that "cannot run". Twice it forced a needless revision loop; only executing the claim refuted it.** Two cheap contract fixes make the reviewer earn a "cannot run/parse/crashes" CRITICAL and remember what's already been disproven. **Three features, all red-first (each carries an ordered `red_handback → impl_handback → green_handback` triple with `red_first` teeth_proof):** (1) `execute-before-critical-rule` — `.copilot/agents/code-review-subagent.agent.md` gains a named **Execute-before-CRITICAL** rule: any CRITICAL of the "cannot run / cannot parse / crashes" class must carry an **executed reproduction** (the command run on the reviewed HEAD + observed output); without one the finding is reported as **MAJOR, confidence: low, never CRITICAL** — static reasoning alone can never mint a CRITICAL of this class (the read-only reviewer may discharge the reproduction via the conductor/test-subagent loop); sensor `tests/meta/test_review_execute_before_critical.sh`. (2) `known-false-positive-registry` — new append-only `.copilot/skills/_review-known-false-positives.md` (convention file, no frontmatter, mirrors `_audit-conventions.md`) seeded with the PEP 758 entry (refuted claim, why it's wrong, a real `python3 -c` disproving command honest about the 3.14 version boundary); the reviewer checklist must consult it before raising any syntax/version-support finding; sensor `tests/meta/test_review_known_false_positives.sh`. (3) `registry-feedback-loop` — `.copilot/instructions/harness.instructions.md` review Loop 2 instructs the conductor to append a registry entry whenever a CRITICAL/MAJOR finding is empirically refuted, carrying the real disproving command + observed output (omit-never-fake); sensor `tests/meta/test_review_registry_feedback_loop.sh`. Doc/contract-only (no runtime boundary → no e2e sensor); full sensor suite + shellcheck (CI glob) green.

### harness-gate (#264): make the PR-path gate enforce sensor teeth-proof, not handback ordering
- **#264 — the PR-path red-first gate hard-blocked on handback *ordering* (`red_first_evidence_missing` when a `passes:true` feature lacked a role-correct `red_handback → impl_handback → green_handback` triple, `red_first_role_mismatch` on wrong-role handbacks), while the first-class `teeth_proof` object added in #263 stayed warn-only — so the enforcing teeth were procedure (did you log the triple?) rather than outcome (does a sensor actually have teeth?).** This inverts that: **teeth_proof becomes the hard bar, ordering demotes to warn-only.** Backward-compatible (existing `red_first_waiver` feature lists keep working via aliasing) and shipped as a MINOR bump (observable gate-behavior change). **Five features:** (1) `checker-teeth-proof-satisfies` — `scripts/check-trace-consistency.sh` now treats a `passes:true` feature as satisfied by a valid `teeth_proof` object (kind `red_first`/`mutation`/`negative_fixture` + non-empty evidence) **or** a role-correct ordered triple **or** a governed waiver; it raises `VIOLATION consistency: teeth_proof_missing` when none is present, and demotes the ordering finding to warn-only `WARNING consistency: red_first_ordering_absent` (retiring the `red_first_evidence_missing`/`red_first_role_mismatch` tokens); sensor `tests/scripts/test_trace_red_first_evidence.sh` rewritten to 9 cases. (2) `gate-blocks-teeth-proof-missing` — `scripts/review-gate.sh` `red_first_evidence_gate()` (name kept) now hard-blocks on `teeth_proof_missing` and never on the ordering warning; `create-pr.sh` inherits the block; sensor `tests/scripts/test_red_first_pr_gate.sh`. (3) `waivers-rescoped-teeth-proof` — the canonical waiver key is now `teeth_proof_waiver`, with `red_first_waiver` accepted as a **deprecated alias** (new key wins if both present); `check-trace-consistency.sh` + `check-feature-list.sh` honor either, and a malformed `teeth_proof_waiver` is hard-refused; sensors `test_trace_red_first_evidence.sh` + `test_feature_list_check.sh`. (4) `contract-and-version` — `docs/harness-contract.yml` now declares `scripts/check-trace-consistency.sh` as a first-class contract script and repoints the failure_modes (`missing-teeth-proof-evidence` hard/`review-gate.sh`, `red-first-ordering-absent` warn/`check-trace-consistency.sh`), backstopped in `tests/scripts/test_harness_contract.sh`; `pyproject.toml` + `VERSION` bumped **0.4.0 → 0.5.0** via `scripts/sync-version.sh` (drift-guarded by `test_version_no_drift.sh`). (5) `docs-teeth-obligation` — `docs/HARNESS.md` renames the "Red-first evidence obligation" section to **"Sensor teeth-proof obligation"** (L4 rationale + the `red_first_waiver → teeth_proof_waiver` migration), and `AGENTS.md` golden rule 2 keeps TDD as the default discipline while stating the gate checks **teeth** (a sensor proven able to fail), not ordering; doctrine meta-sensor `tests/meta/test_teeth_proof_doctrine.sh` extended. Full 187-sensor suite + shellcheck (CI glob) all green; delivered red-first (each feature carries an ordered `red_handback → impl_handback → green_handback` triple with `teeth_proof`).

### harness-contract (#263): make per-feature teeth-proof evidence a first-class, contract-declared sensor signal
- **#263 — a `feature_list.json` feature could flip `passes:true` without naming the concrete regression sensor that would fail if the feature regressed ("teeth proof"); the harness counted red-first handbacks but never asked each passing feature to *point at its own teeth*.** This adds an **optional** `teeth_proof` object per feature and wires it end-to-end as a **warn-only coverage signal** (no hard gate — omit-never-fake: a missing proof warns, it does not fabricate one). **Three features:** (1) `teeth-proof-schema-validation` — `scripts/check-feature-list.sh` now validates `teeth_proof` when present (hard-fail on a malformed object; explicit `null` treated as absent, matching the repo's null-as-absent convention for optional fields), warns `teeth_proof_missing` for any `passes:true` feature that lacks one, suppresses that warn under a valid `red_first_waiver`, and emits a numeric `harness.teeth_proof_missing_count` on its EXIT-trap tool span; sensor `tests/scripts/test_feature_list_check.sh` grew scenarios 12–20 (valid proof, malformed subcases, warn-only-missing, waiver suppression, null-as-absent). (2) `teeth-proof-doctrine` — `.copilot/instructions/harness.instructions.md` §3 gained a "Teeth-proof evidence" subsection, `.copilot/agents/test-subagent.agent.md` records `teeth_proof` at the pass flip, and `docs/HARNESS.md` documents it in the Local Tracking table + red-first cross-reference; doctrine meta-sensor `tests/meta/test_teeth_proof_doctrine.sh`. (3) `teeth-proof-contract` — `docs/harness-contract.yml` now declares a `teeth-proof-missing-warn` failure_mode (kind:warn, owner `scripts/check-feature-list.sh`, present `teeth_proof_missing`), backstopped in `tests/scripts/test_harness_contract.sh` so deleting it fails the contract sensor. Stays warn-only forever by design (the red-first *ordering* gate remains the enforcing teeth; teeth_proof is the human-readable pointer). Full 187-sensor suite + shellcheck (CI glob) + `bash -n` all green; delivered red-first (each feature carries an ordered `red_handback → impl_handback → green_handback` triple with `teeth_proof`).

### tooling (#258): `audit-sweep.sh` — run all six audit skills locally in one invocation
- **#258 — the six audit skills (`dead-code-detection`, `find-brute-force`, `find-duplicates`, `find-over-design`, `security-audit`, `sync-docs`) were only invoked one at a time by hand; we wanted a single local entry point that runs all six and produces one consolidated report, without waiting for the blocked (#256) scheduled-CI version.** A single meta-skill running all six audits in one context was **rejected** (six whole-repo audits exhaust the window; later skills degrade) in favor of a deterministic driver + one-shot prompt. **Three features** (the issue's 4th, the sensor, is the TDD vehicle folded into the others). (1) `audit-sweep-script` — `scripts/audit-sweep.sh` loops over the six audit skills **derived from `.copilot/skills/` minus the three non-audit skills** (`code-review`, `create-pr`, `public-exposure-audit`) so adding an audit skill needs no edit; each runs in its own fresh headless `copilot -p` report-only session (`--allow-tool 'read'` + `'shell(git:*)'`, `--deny-tool write`, `--no-ask-user`, `-s`) writing `logs/audit/<UTC-timestamp>/<skill>.md`; subset positional args, `--dry-run` (prints the per-skill commands, launches nothing), unknown-skill fails loudly (exit 2), fail-soft (every skill runs; non-zero exit on any failure). (2) `audit-sweep-consolidation` — `--consolidate <dir>` builds `index.md`: one Findings roll-up table keyed `(skill, severity, priority, file)` above the verbatim per-skill sections. (3) `audit-sweep-prompt` — `.copilot/prompts/audit-sweep.prompt.md` (`mode: agent`, optional `${input:scope}`) drives the script, reads `index.md`, summarizes the Fix-now findings; plus a "Running the audit sweep" note in `docs/HARNESS.md`. Regression sensor: new `tests/scripts/test_audit_sweep.sh` — a fake `copilot` that hard-fails if called proves `--dry-run` stays offline; asserts the dry-run names exactly the six directory-derived skills, every command carries `--deny-tool write`, subset filtering, unknown-skill loud failure, shellcheck-clean, the `--consolidate` roll-up + per-skill sections over fake reports, and the prompt references the script + `index.md`. `logs/audit/` is already gitignored, so sweep reports never land in commits. Cost is identical to today's manual one-by-one runs (same six sessions, batched) — that's what keeps this unblocked while #256 waits; this script becomes that CI job's entry point when #256 unblocks. Full 186-sensor suite + shellcheck (CI glob) + `bash -n` + Python gates all green; reviewed under `REQUIRE_TRACE_CONSISTENCY=1`.

### release (#257): automate SemVer bumps + changelog with python-semantic-release
- **#257 — the harness version was hand-maintained in two files that had already drifted (`VERSION` = `0.1.1`, `pyproject.toml` = `0.1.0`), with no git tags and no changelog.** Adopted [python-semantic-release](https://python-semantic-release.readthedocs.io/) (PSR) so the SemVer bump is *decided at commit time* by the Conventional Commits type and the release mechanics run in CI. **Four features:** (1) `commit-convention-doc` — `AGENTS.md` now pins standard Conventional Commits (`type(scope): subject`) as the required format with the `fix`→patch / `feat`→minor / `BREAKING CHANGE`→major table (sensor `tests/scripts/test_commit_convention_doc.sh`). (2) `version-single-source` — `pyproject.toml [project].version` is the single source of truth (`version_toml`), a new `scripts/sync-version.sh` mirrors it into the root `VERSION` file (PSR `build_command`, committed via `assets`) so `trace-lib.sh` keeps working, and the pre-existing `0.1.0`/`0.1.1` drift is fixed to `0.1.1`; sensor `tests/scripts/test_version_no_drift.sh` asserts `VERSION == pyproject`, PSR config present, `commit_parser = "conventional"` (chore/docs are no-ops), and that `sync-version.sh` repairs a drifted `VERSION`. (3) `release-workflow` — new `.github/workflows/release.yml` (push to `main` → PSR `version` + `publish` action, `contents: write`, concurrency guard, GitHub Release gated on `outputs.released == 'true'`); sensor `tests/scripts/test_release_workflow.sh` validates the YAML + trigger/permission/gate structure. (4) `release-policy-doc` — new `docs/RELEASING.md` documents the auto-release flow and that `0.x`→`1.0.0` is a deliberate **human** decision (`semantic-release version --major` / a `BREAKING CHANGE` commit), not a mechanical bump; sensor `tests/scripts/test_release_policy_doc.sh`. An anchor tag `v0.1.1` was pushed so PSR's first computed release starts from the current version rather than the whole history. Out of scope: PyPI publishing, backfilling historical tags. Full 184-sensor suite + shellcheck (CI glob) + `bash -n` + Python gates (`ruff`/`mypy`/`pytest`) all green; reviewed under `REQUIRE_TRACE_CONSISTENCY=1`. E2E: merging this `feat:` PR to `main` cut the first automated release — but because PSR v10 defaults `allow_zero_version` to `false`, it computed `v1.0.0` instead of the intended `v0.2.0`; corrected in #260 (which pins `allow_zero_version=true` + `major_on_zero=false` and rolls the premature `1.0.0` back to the `0.x` line).

### release (#260): pin `allow_zero_version` so PSR stays on 0.x + roll back premature `1.0.0`
- **#260 — the #257 automation's first live release came out as `1.0.0` instead of `0.2.0`.** Root cause: python-semantic-release **v10 flipped the default of `allow_zero_version` to `false`**, which forces the first computed release to `1.0.0` regardless of the change level — directly violating the `docs/RELEASING.md` policy that `1.0.0` must be a deliberate human decision. **One feature** (`zero-version-policy`): `pyproject.toml [tool.semantic_release]` now pins `allow_zero_version = true` (stay on `0.x` until a human cuts `1.0.0`) and `major_on_zero = false` (a `BREAKING CHANGE` on `0.x` bumps the minor, so `1.0.0` is reachable only via an explicit manual `--major`); the version files are reset to the `0.x` line (`pyproject`/`VERSION` → `0.1.1`) and the premature `v1.0.0` section is dropped from `CHANGELOG.md`, with the erroneous `v1.0.0` git tag + GitHub Release deleted so PSR recomputes from `v0.1.1`. Regression sensor: new `tests/scripts/test_release_zero_version.sh` asserts both config keys are set (fails if either is removed or flipped). E2E: merging this fix re-cuts **`v0.2.0`** (not `1.0.0`).

### closeout (#167): `merge-pr.sh --delete-branch` is worktree-safe and decoupled from the remote merge
- **#167 — `./scripts/merge-pr.sh --squash --delete-branch` from inside an issue worktree left cleanup for the human.** `--delete-branch` was forwarded straight to `gh pr merge`, so gh tried to check out `main` to delete the merged local branch and failed with `fatal: 'main' is already used by worktree` (the primary worktree owns `main`); worse, under `set -e` that local-cleanup failure exited the whole script non-zero, coupling a *successful remote merge* to a failed local cleanup. **One feature** (`worktree-safe-delete-branch`): strip `--delete-branch`/`--delete-branch=*`/`-d` from the `gh pr merge` pass-through so the remote merge runs alone, then — only after it succeeds — run a decoupled, `set +e`, warn-only cleanup block that deletes the remote branch (`git push origin --delete`) and the local branch by **detaching HEAD first** then `git branch -D`, never checking out `main`; any cleanup failure warns with a follow-up command and keeps exit 0. Regression sensor: new `tests/scripts/test_merge_pr_worktree_cleanup.sh` (real repo + bare origin + linked worktree with `main` in the primary, faked `gh`) asserting exit 0, remote+local branch gone, primary `main` untouched, no `already used by worktree`, `--delete-branch` stripped/`--squash` kept, and a decoupled remote-delete failure still exit-0 + warn + local-deleted — RED against the pre-fix script, GREEN after. Full 180-sensor suite + shellcheck (CI glob) + `bash -n` all green; reviewed under `REQUIRE_TRACE_CONSISTENCY=1`.

### docs (#211): sync living documentation — drop the removed `general` skill from `docs/HARNESS.md`
- **#211 — a `/sync-docs` audit of the living documentation (README, `docs/`, `.github/`, `.copilot/` customization, AGENTS.md) against current harness sources after the #219–#225 chain merged.** The audit found that most suspected drift was **already reconciled upstream by the issues that caused it**: the sensor-suite count (**179**) is already correct here in *Snapshot*, and the #220 Python surface (`scripts/trace_tools/`, `uv`/`ruff`/`mypy`/`pytest` gates, the Python-vs-jq decision) is already documented in `scripts-language-policy.md`, `README`, `getting-started`, and `HARNESS.md`. The single confirmed unambiguous factual drift: `docs/HARNESS.md` still presented the **`general` skill — deleted in #177** (`.copilot/skills/` no longer carries a `general/` dir) — as a *live* skill, in the "Skill × subagent × stage" table and in the "carry no distinctive skill beyond `general`" prose; `AGENTS.md`'s sibling table had already been corrected. **One feature** (`general-skill-drift-harness-doc`): remove the stale table row + fix the prose to "carry no distinctive skill" (mirroring `AGENTS.md`), with the past-tense removal narrative in `PROGRESS.md`, `copilot-health-check.md`, and the two modernization-review docs deliberately **preserved**. Regression sensor: a new leg (2b) in `tests/meta/test_skill_references_resolve.sh` that rejects any bare `` `general` `` skill reference in living docs outside the enumerated historical allowlist (the path-form leg #2 didn't catch bare-word mentions); RED against the stale `HARNESS.md`, GREEN after the fix. **Report-only ambiguous findings (not edited, per the issue's "report ambiguous" contract):** (R-1) a CI-workflow source conflict — `harness-smoke.yml` runs the Python gates while `python-ci.yml`'s comment says harness-smoke "deliberately excludes" them; (R-2) `docs/evaluation/README.md` index exhaustiveness. No obsolete-doc deletions were confirmed. Full 179-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest`) all green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #254)_

### deep-trace (#220): step-level log export + `scripts/trace_tools` Python pilot (absorbs #218) — the epic #212 decision gate
- **#220 — the last open child of epic #212: ships the step-level `log.jsonl` stream to Application Insights / OTLP (the export half of the #219 local-capture → #220 export → #221 review-wiring split), AND runs the epic's Python-vs-jq decision gate by piloting a `scripts/trace_tools/` Python package behind `trace-export.sh`'s frozen CLI.** Eleven features, TDD role-separated; the issue edits harness scripts so its own run is the e2e sensor (verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`). **Scope A — Python pilot + byte-parity (BLOCKING #223 protection).** **(1) Scaffold** — root `pyproject.toml` (uv-managed, package at `scripts/trace_tools/`, `ruff`/`mypy --strict`/`pytest`), and `harness-smoke.yml` now installs `uv` + runs the four Python gates before the sensor suite so the toolchain is CI-dogfooded (the scaffold sensor SKIPs uv/python-gated assertions when the tools are absent, per the jq-skip precedent). **(2) App-Insights mapping parity** — `mapping.py` (single-source `ALLOWLIST` replacing the two byte-duplicated jq `def allowlist` blocks) + `appinsights.py` + a `resolve_trace_export_engine` (`TRACE_EXPORT_ENGINE=auto|python|jq`, `auto`→python iff `python3`+`uv`+importable, announces `notice: engine=`) that dispatches the projection to Python and pipes the body through the existing `jq .` so **serialization stays jq-owned and output is byte-identical** across engines. **(3) OTLP mapping parity** — `otlp.py` (resourceSpans, string/int-only nanos, deterministic 32-hex per-issue `traceId`); the parity oracle `test_trace_export_python_parity.sh` pins 46 byte-identical rows and the issue-220 `traceId …dc` under BOTH engines — the guard that keeps #223's App-Insights deep-link stable. **(4) Dispatcher** — `TRACE_EXPORT_ENGINE` documented in `usage()`; `test_trace_export_dispatch.sh` (byte-parity both seams, exit-code parity, auto-fallback, engine genuineness) + `tests/meta/test_trace_export_allowlist_single_source.sh` (allowlist 3-way single-source, mutation-verified). **Scope B — step-level log export.** **(5) Log mapping** — `logmap.py` (OTLP `resourceLogs` + App-Insights `MessageData`; per-issue `traceId` reuse, honest `spanId` omission, severity maps, `ai.operation.id=issue-NN`/`operation_ParentId=span_id`) behind a new sibling `scripts/log-export.sh` dispatcher (`LOG_EXPORT_OTLP` opt-in, jq/python byte-identical, zero-network dry-run seams). **(6) Fail-closed gate** — `log_redaction_gate()` mirrors the span gate: redact-before-cap, hardcoded secret-shape backstop (independent of `trace_redact`), excluded-name belt, 256-char+control-byte value caps, invalid-JSONL disqualifying abort, all-or-nothing (nothing written on failure). **(7) Closeout wiring** — `best_effort_log_export` in `finish-lib.sh` (opt-in, always returns 0, never blocks teardown). **(8) Mid-issue push** — optional `create-pr` log push behind `CREATE_PR_LOG_EXPORT=1`; `LOG_EXPORT_OTLP`/`LOG_EXPORT_OTLP_HTTP`/`CREATE_PR_LOG_EXPORT` flowed through `.env.example`/`gen-export-env.sh`/docs. **(9) Correlation oracle** — `test_log_export_correlation.sh` drives all four dry-run seams over one issue fixture and pins cross-stream `ai.operation.id`/OTLP `traceId` equality + AI/OTLP span linkage (mutation-verified; live ship deferred, human-gated on Azure creds). **(10) Decision-gate verdict** — `docs/scripts-language-policy.md` §2 records the pilot as a **qualified win** for the trace-analytics / data-mapping cluster (jq stays the always-available fallback via the `auto` engine; migration stays trigger-based / never-wholesale; a Phase-2 issue is recommended to consolidate the remaining duplicated jq mapping) — reported to epic #212. **(11) Retention doc** — `telemetry-retention-pii.md` now documents the exportable log stream (opt-in `log-export.sh` ships a redacted+allowlisted **projection**; the raw `log.jsonl` stays gitignored/local; same redact-before-cap + deny-by-default governance as spans; unified live-Terraform 30-day retention). New sensors: scaffold, python-parity, dispatch, allowlist-meta, `test_log_export_mapping.sh`, `test_log_export_otlp_mapping.sh`, `test_log_export_redaction.sh`, `test_finish_issue_log_export.sh`, `test_create_pr_log_export.sh`, `test_log_export_correlation.sh`, plus extended env/docs/policy/retention/coupling sensors. Full 178-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest 43`) all green. _(PR #251)_

### dashboard (#224): version-comparison tab consolidation + `{Version}` multi-select parameter (3/4)
- **#224 — Part 3 of 4 of the workbook redesign: the by-`harness.version` comparison tab (Tab 3) gains a multi-select `{Version}` filter and factors the repeated per-panel boilerplate into one base query per table, with strict output parity for an unfiltered selection.** Four features, all fixture-provable via `test_trace_dashboard_pack.sh` (no runtime boundary → no e2e). **(1) Base-query hoist** — the shared `extend hv = tostring(customDimensions['harness.version'])` prelude repeated across all 8 by-version panels is factored into two workbook parameters `CmpDepBase` (the 7 `dependencies` panels) and `CmpEvtBase` (`token-cost`, `customEvents`); each panel now reads `<table> | where timestamp {TimeRange} | {CmpDepBase|CmpEvtBase} | extend <panel-specific> | …`, a pure refactor (chained `extend` is order-independent, so every `where`/`summarize`/`project`/`order by` and the `summarize … by hv` denominators are byte-identical). **(2) `{Version}` multi-select** — a data-populated multi-select dropdown parameter (`multiSelect`+`includeAll`, `*` all-value sentinel, populated by `distinct hv` over the `harness.version` dimension); the base fragments carry the **canonical** Azure-Workbooks multi-select no-op filter `where '*' in ({Version}) or hv in ({Version})` so an unfiltered ('All') selection is a provable no-op that reproduces the pre-change aggregates (same numbers, same denominators) while a specific selection filters — **not** the single-select `'{Version}' == '*'` form (which errors/drops-all under multi-select; caught in code review). **(3) Deferred-metrics verbatim guard** — a new drift leg pins the compare tab's `deferred-metrics` honesty block byte-for-byte (6 fingerprint strings, tab+item scoped, mutation-proven) so the refactor cannot silently alter it; guard-only feature under a governed `justified` red-first waiver. **(4) README** — the dashboards README `Version comparison` bullet documents the multi-select `{Version}` filter (honest 'All' no-op parity) and the per-table base-query hoist. All KQL stays allowlist-clean; the drift sensor gained four `#224` legs (hoist, version-filter, deferred-verbatim, README), each mutation-verified. Full 179-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest 43`) all green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. Non-blocking follow-up: a one-time manual 'All' render at next deploy closes the live-Azure loop the static sensors can't execute. _(PR #253)_

### dashboard (#225): Tab 2 failure-detail log panel + honest empty-state (4/4 — gated on #220)
- **#225 — Part 4 of 4 of the workbook redesign: the single-run drill-down tab (Tab 2) gains the failure-detail LOG panel that #223 shipped as deferred/gated-on-#220, now that #220's log-export stream is live.** Three features, all fixture-provable via `test_trace_dashboard_pack.sh` plus one runtime e2e (`test_log_failure_panel_shape.sh`). **(1) Failure-detail log panel** — a new `drilldown-failure-detail-log` KqlItem queries the App-Insights `traces` table scoped to the run (`operation_Id == 'issue-{Issue}'`), filters FAILURE records (`severityLevel >= 3 AND customDimensions['harness.outcome'] == 'fail'`, matching #221's failure definition), projects the 7 traces-shaped columns, and correlates to the failing span via `operation_ParentId` (the log's `span_id`, NOT `parent_span_id` which stays the panel-6 waterfall's). Its e2e drives `log-export.sh --dry-run-logs-to-file` over a real FAILURE fixture and pins all 7 columns + zero-network. **(2) Honest empty-state** — because Azure `conditionalVisibility` can't key off row count, the KQL uses an always-one-row `let failures = …; failures | union (print … message = 'log evidence unavailable' … | where toscalar(failures | count) == 0)` construct (matching `print`/`project` column types) so the panel renders explicit `log evidence unavailable` when a run has no failure logs — never an empty chart, never inferred health. **(3) Docs + drift flip** — the README panel→contract map row and the workbook `drilldown-header` both flip deferred→shipped (all `#220`/gated language retired from README and workbook), the map row names `traces` + `log-schema.v1.json (#219)` + the six allowlisted keys + an honest caveat; the drift sensor gains a workbook-JSON leg guarding the header against stale log-panel deferral (scoped to not trip the legitimate `deferred-metrics` block) and a tightened README `#220` guard. Full 179-sensor suite + shellcheck + L0 + Python gates (`ruff`/`mypy`/`pytest 43`) all green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #252)_

### dashboard (#223): single-run drill-down tab (Tab 2) — lifecycle timeline, TDD loop strip, tool/skill, cost, transaction deep-link
- **#223 — Part 2 of 4 of the workbook redesign (`docs/evaluation/dashboards/workbook-redesign.md`): the deployed Azure Workbook gains a `{Issue}`-parameterized single-run drill-down tab, the view that answers "did this issue's workflow execute correctly, and where did it stall". Depends on #222 (Tabs 0–1, the `{Issue}` drill-through export).** Seven features, all fixture-provable via the `test_trace_dashboard_pack.sh` drift sensor (no runtime boundary → no e2e). **(1) Tab container** — a 4th `tabs` links entry `subTarget:"drilldown"` (ordered between `issues` and `compare`) + a conditionally-visible `type:12` group `tab-drilldown` (gated `selectedTab==drilldown`) with a header naming `{Issue}`, the honesty stance (missing/out-of-order steps read as a gap; empty `{Issue}` is honestly no-run), and the deferred-#220 log-panel note. **(2) Lifecycle step timeline** — `drilldown-lifecycle-timeline` KqlItem: per-issue lifecycle spans ordered by timestamp with `harness.duration_ms` + outcome formatting, so a missing/out-of-order step shows as a gap (the human-scannable twin of the code-review trace gate). **(3) Per-feature TDD loop strip** — `drilldown-tdd-loop-strip`: per `harness.feature_id` red/impl/green handback counts with role via `harness.subagent` (NOT the un-allowlisted `harness.role`) and an amber `reentries>0` highlight = honest `red_reentry`, never relabeled "first-pass green". **(4) Tool & skill calls** — `drilldown-tool-skill-calls`: per-run `gen_ai.tool.name`/`harness.skill.name` volume, `fail_calls`, max duration (measured-zero vs absent explicit; per-feature attribution still deferred). **(5) Cost strip** — `drilldown-cost-strip`: `customEvents` tokens by agent/model with `tokens_status` honest-null (`unavailable`, never a fabricated 0) + the `#163` Copilot-side-gap pointer. **(6) Transaction deep-link** — `drilldown-transaction-deeplink` type:11 `Url` link-OUT keyed on `operation_Id = issue-{Issue}`, resolving the component via the workbook `source_id` (no committed resource-id/GUID literal), linking to the native App Insights end-to-end waterfall (deterministic per-issue TraceId + `parent_span_id` #174) rather than rebuilding it in KQL. **(7) Honesty + map coherence** — the deferred failure-detail LOG panel (Tab 2 panel 4, gated on #220) is NAMED as deferred/unavailable in BOTH the workbook Tab 2 header and a README panel→contract map row, and the README map rows every shipped Tab 2 panel. All KQL is allowlist-clean (parsed live from `trace-export.sh` `def allowlist:`); the drift sensor `test_trace_dashboard_pack.sh` gained a `#223` leg per feature (Tab-2-scoped, single-query-carries-all-markers, mutation-verified). Full 168-sensor suite + shellcheck + L0 green; `terraform fmt` clean; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #250)_

### deep-trace (#221): wire step-level logs into review evidence, trace-report, and the accuracy matrix
- **#221 — Part 3 of 3 of the deep-trace split: the step-level `log.jsonl` from #219 is now wired into the three surfaces that consume trace evidence, so a failed gate's actual output (not just a span's capped summary) reaches the reviewer, the report, and the eval matrix. Export stays out of scope (this issue depends only on #219).** Four features, all fixture-provable (no runtime boundary). **(1) code-review evidence** — the `code-review-subagent` `## Trace / Process Evidence` section gains a sub-bullet: a BLOCKING/CRITICAL *process* finding derived from trace evidence must quote the corresponding `log.jsonl` failure record — the `error`-level record with `harness.outcome == "fail"` for that `harness.stage`, citing its redacted/capped `payload` (the actual failing output) — instead of only the span's summary; and when `log.jsonl` is absent or has no matching record, the reviewer states `log evidence unavailable`, never inferred as pass (mirrors the existing `trace evidence unavailable` rule). **(2) trace-report** — `trace-report.sh` additively surfaces `log_failures` in the summary object + markdown, read from the sibling `log.jsonl`: `{ total, by_stage }` counting `level=="error" && harness.outcome=="fail"` grouped by `harness.stage`, `null` when no `log.jsonl` (absence explicit, "log evidence unavailable"), and measured `0`/`{}` when present-with-none — additive/open-world, the frozen summary shape and `required_top_level` untouched, never-crash (exit 0, silent stderr) preserved; documented in `trace-summary.v1.json`. **(3) accuracy matrix** — `agent-delivery-accuracy-matrix.md` "Source contracts and boundaries" registers `log.jsonl`/`log-schema.v1.json` as the per-run **failure-detail** evidence source with an explicit can/cannot boundary (supplies the actual failing output behind a process finding; is the detail stream, not itself a correctness label; absence is `null`, never zero failures), mirrored as a `notes.log_evidence_source` line in `agent-delivery-accuracy-matrix.v1.json`. **(4) drift sensor** — a new meta sensor `test_log_schema_single_source.sh` (Approach A key-coverage, #173/#201 pattern) pins every log field the review prompt + `trace-report.sh` reference (`level`/`error`, `harness.outcome`/`fail`, `harness.stage`, `payload`, `message`) to `log-schema.v1.json` so a schema rename or an undocumented field reference fails the sensor (mutation-verified; no schema change needed — the fields were already documented). New sensors: `test_trace_report_log_failures.sh` (3 legs: null / counts-by-stage / measured-zero), `test_log_schema_single_source.sh`; extended `test_code_review_trace_evidence.sh` (+5 log-detail assertions) and `test_agent_delivery_accuracy_matrix_doc.sh` (+7 log-source assertions). Full 168-sensor suite + shellcheck + L0 green; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #249)_

### deep-trace (#219): local step-level log capture (`trace_log` + `log.jsonl`, redaction-first, on-by-default local)
- **#219 — completes the OTel traces-vs-logs split for harness self-development: spans already carry shape/timing (capped 200/500-char summaries), and now a local, gitignored `log.jsonl` captures step-level DETAIL so a failed gate or sensor's full output survives post-hoc, correlated to spans by id.** Part 1 of 3 (local capture #219 → export #220 → review/eval wiring #221). A new **`trace_log <level> <message> [key=value...]`** sibling of `trace_span` in `scripts/trace-lib.sh` appends one schema-v1 JSONL record per call to the **main-root-pinned** `.copilot-tracking/issues/issue-NN/log.jsonl` (beside `trace.jsonl`, surviving worktree teardown), reusing `trace__main_root`/`trace__resolve_issue`/`trace_redact` and the same warn-and-`return 0` **NOOP-degradation** contract (nine features). **(1) Schema** — its own `docs/evaluation/log-schema.v1.json` (distinct `log_schema_version` key so a shared validator never confuses a log line for a span: `levels` enum `info|warn|error`, five `required_common` keys `log_schema_version`/`timestamp`/`level`/`harness.issue`/`message`, `optional_fields` incl. `span_id`/`parent_span_id` correlation, `log_file.path`, redact-before-cap `redaction`), documented in `observability-and-trace-schema.md`. **(2) Core emit** — required fields auto-stamped, append-only, unknown level dropped, `key=value` folded with reserved-key protection, `span_id` stamped from `TRACE_LAST_SPAN_ID` (omit-never-fake). **(3) Redaction** — the `payload` value is `trace_redact`-ed **before** capping to `HARNESS_LOG_PAYLOAD_CAP` (default 4096 B), then a final whole-line `trace_redact` pass, so a secret-shaped input never reaches disk **even truncated** (the #242 redact-before-cap rule). **(4) Kill switch** — `HARNESS_LOG=0` is a NOOP; default (unset) captures, mirroring `progress.md`; remote export stays separately opt-in (#220). **(5) Failure isolation** — every `trace_log` failure path warns and returns 0, so a `set -euo pipefail` caller survives; absent trace-lib leaves lifecycle unchanged (characterization sensor, mutation-verified). **(6) Lifecycle** — each armed lifecycle step emits one `info` start line (in `trace_lifecycle_arm`) and one end line with outcome/exit_status (in `__trace_lifecycle_exit`) via the shared trap; un-armed runs stay silent; span emission unchanged. **(7) Failure-capture** — a failing-gate fixture proves full bounded output is captured at `error` level (`harness.outcome=fail`, `payload≤cap`, redacted); a passing gate writes no error line (real-gate wiring deferred to #221). **(8) PII governance** — `telemetry-retention-pii.md` names `message`/`payload` as excluded redacted free-text log fields and documents `log.jsonl` local-only (never the remote export window). **(9) Sanitizer parity** — `sanitize-trace.sh` (key-agnostic byte-wise redaction) cleans a synthetic `log.jsonl` fail-closed. New sensors: `test_log_schema.sh`, `test_trace_log.sh`, `test_trace_log_redaction.sh`, `test_trace_log_killswitch.sh`, `test_trace_log_isolation.sh`, `test_trace_log_lifecycle.sh`, `test_trace_log_failure_capture.sh`, `test_log_pii_governance.sh`, `test_sanitize_log_fixture.sh`. Full 166-sensor suite + shellcheck + L0 green; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #248)_

### subagent-observability (#242): fix OTel Path O enrichment timing, join tolerance, fallback gating + name cap
- **#242 — subagent-name enrichment now happens when the join targets actually exist, survives the real v1.0.70 exporter file shape, gates OTel correctly with an events fallback, and can never ship an unbounded attribute.** The #227 enrichment resolved the subagent name inline at `postToolUse`, but OTel spans flush **children before parents** (measured v1.0.70), so at an inner subagent tool's `postToolUse` the `invoke_agent` wrapper span is not yet on disk — the join was fundamentally too early. Six features: **(F1)** spike doc §7 records the v1.0.70 MEASURED Path O contract — `attributes` is an object on span lines / metric lines carry none, children-flush-before-parents (append order == span-end order), and the corrected **structural** join (`toolu_X` → `execute_tool` `gen_ai.tool.call.id` → child `invoke_agent` `parentSpanId` → `gen_ai.agent.name`; the wrapper span's own tool.call.id is null). **(F5)** `postToolUse` now only stamps `harness.subagent="true"`; a new `hook__retro_upgrade_subagents` runs at `subagentStop`/`agentStop`/`Stop`, resolves each `toolu_`-session tool span marked `"true"` to its real agent name and rewrites the matching lines **in place** (atomic tmp+mv, re-redacted, idempotent, degrade-never-drop; non-matching lines byte-identical) — with a `trace-schema.v1.json` carve-out for the in-place upgrade. **(F2)** `hook__otel_agent_name` replaced its `jq -rs` slurp with a line-tolerant `jq -Rrn` (`inputs | fromjson?`) + `.attributes|type=="object"` guard, so a metric line, a non-object `attributes`, or a truncated final line no longer aborts the whole parse and drops the join. **(F4)** `hook__resolve_subagent_name` now attempts the OTel join only when `COPILOT_OTEL_ENABLED` is truthy (non-empty, not `0`/`false`) **AND** the exporter path is set — matching the CLI's real export precondition — and **falls through** to the `events.jsonl` fallback on an OTel miss instead of suppressing it whenever the path is set. **(F6)** a pre-existing `trace_redact` bug (its unquoted `key=value` sed value classes consumed the JSON escape backslash before an embedded escaped quote, invalidating the span line) is fixed by excluding backslash from the value class (`[^"\\[:space:]]+`) — real secrets (`ghp_`/`sk-`/`TOKEN=`/JWT) still redacted. **(F3)** the export-allowlisted `harness.subagent` value is bounded by a new `HOOK_SUBAGENT_NAME_CAP=120` (trailing `...`, applied after sanitize, single point covering both the resolve and retro-upgrade paths). New sensor `tests/meta/test_copilot_spike_doc_measured_v1_0_70.sh`; the enrichment sensor `test_copilot_hook_otel_enrichment.sh` rewritten to two-event timing (OTel + events retro-upgrade, OTel-gone-before-stop fallback) plus mixed-shape, half-filled-.env, OTel-miss-fallthrough, and name-cap cases; `test_trace_lib_redaction.sh` gains the JSON-escaping regression. Live e2e: this issue's own trace shows subagent tool spans retro-upgraded to `general-purpose`/`planning-subagent` (not `"true"`). Full 157-sensor suite + shellcheck + L0 green; verified non-dark under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #247)_

### trace (#244): auto-load local trace export env at finish closeout
- **#244 — after a one-time `./scripts/gen-export-env.sh` in the main checkout, issue closeout now exports the trace to App Insights automatically — even when finishing from a worktree — without every terminal having to `source .env` first.** Previously `finish-issue.sh`/`finish-lib.sh` only attempted the best-effort OTLP export when the *current shell* already carried both `TRACE_EXPORT_OTLP=1` and `APPLICATIONINSIGHTS_CONNECTION_STRING`, so the gitignored `.env` written by `gen-export-env.sh` silently did nothing unless manually sourced. A new **data-only allowlist loader** `load_env_allowlist` in `scripts/finish-lib.sh` reads the main-checkout `.env` line-by-line, keeps ONLY the six trace-export keys (`TRACE_EXPORT_OTLP`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `TRACE_EXPORT_OTLP_HTTP`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`), strips one quote layer + unescapes the `gen-export-env` single-quote escape, and `export`s each key **only if unset** so the process env still wins per key. It treats `.env` as DATA — it never `source`s the file and never executes command substitution/backticks stored in a value (proven by a negative/no-exec sensor). `best_effort_trace_export` now calls the loader on `${SCRIPT_DIR}/../.env` (guaranteed the main root — `finish-issue.sh` refuses to run from a worktree) before its export gate; an absent/incomplete `.env` stays the current clean no-op, export remains best-effort (failure warns, teardown continues), and secrets are never printed. `docs/runtime-adapters/otlp-azure-monitor.md` documents the closeout auto-load (scoping the prior "nothing is auto-sourced" note to the manual/interactive flows). New sensors `test_finish_env_allowlist.sh` (6 cases: allowlist-only, quote round-trip, process-env precedence, no-exec, secret-not-echoed, absent-file) and the real-closeout e2e `test_finish_issue_env_autoload.sh` (autoload → exporter invoked, process-env override, no-`.env` no-op mutation guard, secret-safety); `test_export_env_docs.sh` extended with the auto-load assertions. Full 156-sensor suite + shellcheck + L0 green. _(PR #248)_

### trace (#243): launch-topology contract + dark-run liveness sensor (guarantee runtime hook capture)
- **#243 — a conductor session launched from an untrusted cwd (e.g. `$HOME`) never loads `.github/hooks/`, so the trace hook never fires and hundreds of tool executions produce ZERO runtime spans (the #227/#228/#238 392-span silent loss). This issue makes that failure loud on three surfaces.** (1) **Launch-topology contract** documented in `AGENTS.md` (*Start every session here*) and `.copilot/instructions/harness.instructions.md` (§2 step 1): a Copilot CLI conductor session MUST start from the repo root — a trusted folder containing `.github/hooks/`; the CLI loads workspace hooks from the session cwd, so an untrusted cwd silently skips them and the whole run is a "dark run"; includes the `~/.copilot/config.json` `trustedFolders` precondition for new machines. (2) **Best-effort preflight** in `scripts/start-issue.sh`: a non-blocking yellow stderr warning when `.github/hooks/harness-trace.json` is absent at the main root — advisory only, never changes control flow or exit codes; silent when present. (3) **Dark-run liveness sensor** in `scripts/check-trace-consistency.sh`: a *completed* issue window (both `worktree_create` AND `finish` lifecycle spans) that captured ZERO runtime tool spans is flagged `VIOLATION consistency: dark_run <issue>`. A runtime tool span is precisely `span==tool` carrying a string `harness.session_id`; harness-internal tool spans (review-gate.trace, check-feature-list) lack it and cannot mask a dark run. Warn by default, **blocking under `REQUIRE_TRACE_CONSISTENCY=1`** (reuses the existing `review-gate.sh`/`finish-lib.sh` violation-count promotion — no new gate plumbing, no frozen-contract edit); an incomplete window or the documented `TRACE_ALLOW_DARK_RUN=1` override NOTE-skips. New sensors `test_launch_topology_docs.sh`, `test_start_issue_hook_preflight.sh`, `test_trace_consistency_dark_run.sh` (incl. a D7 e2e leg that drives `review-gate.sh trace` warn/blocking and a mutation check). Full 154-sensor suite + shellcheck + L0 green; this issue's own run was verified non-dark (runtime spans present in its trace) under `REQUIRE_TRACE_CONSISTENCY=1`. _(PR #245)_

### subagent-observability (#238): local `.env` setup + generator for App Insights / OTLP trace export
- **#238 — trace export is now turnkey locally: the one shared `.env.example` documents every export knob, a generator writes the sensitive connection string into a gitignored `.env` without echoing it, and the adapter doc teaches the three flows.** Extends the single shared `.env.example` (from #227, no second env path) with empty, non-secret placeholders for the full trace-export contract — `TRACE_EXPORT_OTLP`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `TRACE_EXPORT_OTLP_HTTP`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS` — alongside the existing `COPILOT_OTEL_*` keys. New `scripts/gen-export-env.sh` seeds `.env` from the template when absent, reads `terraform output -raw connection_string` (the Terraform output is `sensitive = true`) and **upserts** `TRACE_EXPORT_OTLP=1` + the connection string **single-quoted** (so `;`/`=`/`/` survive `set -a; source .env; set +a`) and **never echoed** — idempotent, preserving unrelated keys, `chmod 600`, and failing without writing a secret when Terraform yields nothing. The export gate itself is **unchanged**: a characterization sensor freezes the pre-existing opt-in contract (`trace-export.sh` Gate 0 no-op without the flag; `best_effort_trace_export` no-ops without flag+secret, invokes the exporter only when both are set, and swallows exporter failure returning 0). `docs/runtime-adapters/otlp-azure-monitor.md` gains a **Local `.env` setup** section covering the generated-setup, manual-export, and closeout flows, the load idiom, and the never-commit warning. New sensors `test_env_example_export_vars.sh`, `test_gen_export_env.sh`, `test_export_optin_contract.sh` (justified red-first waiver — behaviour predates the issue), `test_export_env_docs.sh`. Full suite + shellcheck green. _(PR #248)_

### subagent-observability (#228): capture Claude Code subagent identity + SubagentStop skill inventory
- **#228 — the Claude Code trace hook now stamps subagent identity on tool/skill spans, names the subagent at `SubagentStop`, and backfills skills the live hook missed.** Built on the documented Claude Code hooks contract (`agent_id`/`agent_type` common fields, `agent_transcript_path` on `SubagentStop`): (1) `hook__on_post_tool_use` reads `agent_id` (present only in subagent context) and stamps `harness.subagent` (the `agent_type`, or `"true"` when the type is absent) so subagent calls split from the conductor's, and mints the `Skill` tool as a first-class span (`gen_ai.tool.name=skill` + `harness.skill.name`, tolerant `.command`/`.name`/`.skill` read) — parity with the Copilot adapter (#138). (2) The `SubagentStop` `agent` span now uses the real `agent_type` as `gen_ai.agent.name` (falling back to `claude-code-subagent`) and carries `harness.session_id` to link the parent session; the conductor `Stop` span is left byte-stable. (3) A **skill inventory backstop** replays `agent_transcript_path` at `SubagentStop`, emitting one skill span per `Skill` call with no corresponding live-captured span (dedup scoped to the subagent via `harness.subagent`, redact+cap on the name); an unreadable/corrupt transcript `trace_warn`s and backfills nothing — *omit, never fake*. (4) `hook__state_file`'s duration key now folds in `agent_id`, so a subagent `PostToolUse` can never consume the conductor's `PreToolUse` start time (or vice versa) when both drive the same `tool_use_id`. `harness.subagent`/`harness.skill.name` were already allowlisted+documented from #227/#138 (no export/schema surface change beyond noting Claude parity). New sensors `test_claude_hook_subagent_stamp.sh`, `test_claude_hook_subagent_stop_enrich.sh`, `test_claude_hook_skill_inventory.sh`, `test_claude_hook_agent_id_state.sh` (RED verified without fix) plus the `claude-code` adapter guide's subagent-capture section — all red-first. Claude hook regressions + full suite green; shellcheck clean. _(PR #248)_

### subagent-observability (#227): capture Copilot subagent tool/skill spans + best-effort OTel Path O agent-name enrichment
- **#227 — the Copilot trace hook now marks tool/skill calls made *inside* a subagent and, best-effort, names the subagent from the official OTel file export.** Built on the #226/#231 spike (measured on Copilot CLI v1.0.69): a `toolu_`-prefixed runtime `sessionId` is the spawning `task` tool-use id, so every `tool`/`skill` span from such a session is stamped `harness.subagent` (deterministic string `"true"`) in `hook__on_post_tool_use`, and the `toolu_` binding is persisted (after git/marker/interval resolution) so later calls in the same subagent stay attributed — an unbindable, interval-ambiguous `toolu_` session still DROPS with a `trace_warn`, never mis-attributes. A new `hook__on_subagent_start` mints one `invoke_agent` agent span carrying `gen_ai.agent.name` (generic-subagent fallback when the payload omits it), symmetric with `subagentStop`; `subagentStart`/`SubagentStart` are dispatched and registered in the hooks template (`preToolUse` remains FORBIDDEN — never registered). **Best-effort OTel Path O enrichment (spike §7):** when Copilot runs with the official file exporter (`COPILOT_OTEL_FILE_EXPORTER_PATH`), `hook__resolve_subagent_name` joins `toolu_<taskId>` → the OTel `execute_tool task` span's `gen_ai.tool.call.id` → the child `invoke_agent` span's `gen_ai.agent.name` and UPGRADES `harness.subagent` from `"true"` to the real agent name (jq reader tolerant of nested/flat attribute shapes and `spanId`/`span_id` variants); with the exporter off it falls back to the conductor `events.jsonl`. The enrichment shares the token-read trust class — a missing/corrupt/non-matching source NEVER drops the deterministic hook span, it degrades to `harness.subagent="true"`, and the whole hook stays exit-0/empty-stdout. **Wiring (Task 4, the shared `.env` landing #238 extends):** a committed `.env.example` carries `COPILOT_OTEL_ENABLED`/`COPILOT_OTEL_FILE_EXPORTER_PATH` placeholders (no real secret) with the explicit `set -a; source .env; set +a` load idiom — env is never auto-sourced; `.copilot-tracking/otel/` is gitignored; `harness.subagent` is allowlisted in both `trace-export.sh` projections (27 keys) and documented in `trace-schema.v1.json` `optional_fields`; the `github-copilot` adapter guide gains a subagent-capture section + capability-matrix row. New sensors `test_copilot_hook_subagent_start_span.sh`, `test_copilot_hook_otel_enrichment.sh` (OTel join / corrupt-degrade / absent / events fallback), `test_copilot_subagent_env_and_allowlist.sh`, extended `test_copilot_hook_session_binding.sh` (`toolu_` bind/stamp/drop cases) and `test_copilot_adapter_docs.sh` (`subagentStart` + D10 pins) — all proven red-first. Full suite 143/0; shellcheck clean. _(PR #248)_

### scripts-portfolio (#216): active-issue marker at start-issue; demote copilot-hook interval scan to last resort (P-5)
- **#216 — the copilot trace hook now attributes conductor-topology spans from a cheap active-issue marker first, and only falls back to the O(N) interval scan.** `scripts/copilot-trace-hook.sh`'s interval-scan attribution (reconstructing every issue's open/close window from on-disk lifecycle spans) is the harness's most fragile logic. `start-issue.sh` now records a tiny per-issue marker file `.copilot-tracking/active-issues/<N>` (content = whole-second UTC window-start ISO), main-root anchored and gitignored, best-effort so a marker-write failure never breaks the lifecycle. The hook gains `hook__resolve_issue_by_marker`, consulted in `hook__main` AFTER git + session binding but BEFORE the interval scan: it attributes only when exactly ONE live marker exists, the payload timestamp is `>= start`, and a staleness guard confirms the issue has emitted no `finish`/`pr_merge` edge — 0 or >1 markers, a pre-window payload, or a stale marker all DEFER to the interval scan, never mis-attribute. **Principled deviation from the issue's "a small file" (singular):** per-issue files (not one shared file) make concurrency cheaply detectable by glob count, which is exactly what the issue's own strict safety rule ("ambiguous → drop, never mis-attribute") demands — a single shared file cannot distinguish one live issue from a race. The interval scan is retained verbatim as the last resort. `finish-lib.sh best_effort_state_hygiene` sweeps ONLY our own marker at closeout, leaving concurrent issues' markers intact. `tests/scripts/test_copilot_hook_interval_attribution.sh` gains cases M1–M5 (marker fast-path hit discriminated from interval, pre-window decline, stale-marker decline, concurrency defer, and the marker-removed mutation baseline — M1 proven red-first); `test_finish_issue_state_hygiene.sh` asserts start-issue writes the marker and finish sweeps our own while sparing a concurrent issue's. Also fixed a pre-existing trace-isolation leak in `test_merge_pr_ci_gate.sh` (it ran `merge-pr.sh` from the real worktree, so its `pr_merge` spans branch-resolved to the live issue and leaked into the real trace) by running it from an isolated fixture repo with `TRACE_ISSUE` unset. Full harness sensor suite (`tests/scripts` + `tests/meta`) and L0 suite pass; shellcheck clean on both 0.9.0 (CI) and 0.11.0. _(PR #248)_

### scripts-portfolio (#215): split finish-issue best-effort helpers into a sourced lib (P-4)
- **#215 — `finish-issue.sh` is a thin teardown orchestrator again; its closeout helpers now have one home in `scripts/finish-lib.sh`.** The script had grown into a second conductor (completion check + trace gate + trace export + trace reconstruct + state hygiene + worktree teardown, every new closeout feature landing here). The four best-effort / gate helpers move into a single sourced `scripts/finish-lib.sh`: `finish_trace_gate` (the two-phase trace gate, now a function that RETURNS 0=proceed / 1=block so the caller keeps its single `exit 1` path and byte-identical messages), plus `best_effort_trace_export` (#144), `best_effort_trace_reconstruct` (#149), and `best_effort_state_hygiene` (#175) — the three `best_effort_*` helpers still ALWAYS return 0 and read the MAIN-checkout trace file, so the documented ordering constraint (trace reads happen AFTER worktree removal, trace-lib pins to main root) is preserved. `finish-issue.sh` guarded-sources the lib (mirroring the existing `trace-lib.sh` guard) with NOOP fallbacks so a missing lib never breaks teardown, and replaces the inline gate block with `finish_trace_gate || exit 1`. 284 → 211 lines (net reduction). `docs/harness-contract.yml` declares the new lib and relocates the `TRACE_EXPORT_OTLP` env-flag owner to it (obligation preserved, relocated by the extraction); the contract sensor's owner allowlist is widened to match. Every test fixture that copies `finish-issue.sh` now also copies `finish-lib.sh` (dependency fidelity — no assertion changed), and `finish-lib.sh` joins the trace-export decoupling allowlist as the sanctioned closeout-export caller. New `tests/meta/test_finish_lib_extracted.sh` drift sensor (proven red-first, 9 violations) pins the extraction: the lib defines the four helpers, `finish-issue.sh` sources + delegates and no longer re-inlines the bodies, and the orchestrator stays under 240 lines. The four issue-named tests (`test_finish_issue_reconstruct/state_hygiene/trace_export`, `test_trace_finish_issue`), the full harness sensor suite, and the L0 suite pass; shellcheck clean on both 0.9.0 (CI) and 0.11.0. _(PR #248)_

### scripts-portfolio (#217): record the scripts language & structure policy (docs, P-6/P-7/P-8)
- **#217 — the `scripts/` language & structure policy now has one page of record so future sessions don't relitigate it.** New `docs/scripts-language-policy.md` states, per cluster: (1) the **lifecycle core** (init, start/finish-issue, create/merge-pr, review-gate, libs, installer, scaffolder), **trace emission** (`trace-lib.sh`, `log-handback.sh`), and **both runtime hooks** stay bash indefinitely — the hooks' exit-0/empty-stdout/no-per-call-interpreter session-safety contract makes a rewrite a non-starter; (2) only the **six trace-analytics tools** (export, validate, report, scorecard, consistency, sanitize) may become Python — trigger-based, behind their frozen CLI contracts (args, exit 0/1/2, output files) with the bash suite as the regression harness, staged one-pilot-first, homed at `scripts/trace_tools/`; (3) split thresholds — `review-gate.sh` splits into `review-gate.d/` only when the next gate is added, the directory stays flat (frozen paths), and there is no unified `harness` mono-CLI. Linked from `docs/HARNESS.md`'s Core Harness layers bullet and cross-referencing `docs/scripts-portfolio-review.md` as the rationale record. New `tests/meta/test_scripts_language_policy_doc.sh` (docs TDD-equivalent, proven red-first) guards the page's presence, the three recorded decisions, the HARNESS.md link, and the rationale cross-reference. _(PR #248)_

### scripts-portfolio (#214): extract the reconcile skeleton shared by the two installers (P-3)
- **#214 — the dry/write/update three-way reconcile skeleton now has one home in `scripts/reconcile-lib.sh`.** `install-harness.sh` and `scaffold-language.sh` each carried a ~40-line `reconcile()` that only differed in (a) how the desired content is compared/materialised — a real source file (`cmp`/`cp`/`diff`) vs an in-memory canonical string (`printf`-piped `cmp`/`diff`) — and (b) whether a `--write` over a differing target is refused. The shared `reconcile_entry <display_path> <mode> <refuse_on_write> <target_missing>` owns the create-missing / up-to-date / update|refuse|advise flow and delegates comparison, materialisation, and diff to three caller-defined hooks (`rc_equal`/`rc_write`/`rc_diff`) set by each caller's thin `reconcile()` wrapper. Install passes `refuse_on_write=1` (keeps its `--write` refuse-and-exit-non-zero on a differing harness file); scaffold passes `0` (keeps its advise-only `--write`). Behaviour is byte-identical — same messages (including the `—` em-dash), same exit codes — so `tests/scripts/test_install_harness.sh` and `tests/scripts/test_scaffold_language.sh` pass UNCHANGED. The lib ships with the harness via the existing wholesale `scripts` `HARNESS_ASSETS` entry (no redundant manifest line). New `tests/meta/test_reconcile_lib_extracted.sh` drift sensor (proven red-first, 9 violations) asserts the lib owns the skeleton messages, both callers source and delegate, and neither re-inlines a private copy. _(PR #248)_

### Subagent-observability spike follow-up (#231): measure OTel file export (Path O) + async subagent coverage
- **#231 — the #226 verdict now has a §7 recording a third capture path (the official OpenTelemetry file export) and async/background coverage, all live-captured on Copilot CLI v1.0.69.** `docs/runtime-adapters/github-copilot.subagent-spike.md` §7 answers: (a) **Path O nests the subagent natively** — `invoke_agent <subagent>` is parented by the conductor's `execute_tool task` span in one `traceId`, carrying **native, non-content-gated** `gen_ai.agent.name`/`agent.id`/`request.model`/`agent.type=custom` (so "which subagent produced this span?" is answerable without any undocumented file); (b) **resolves #3725** — the `execute_tool skill` span carries `github.copilot.tool.parameters.skill_name` **even with content capture OFF**, so the CLI *does* have skill attribution (the community claim is wrong for v1.0.69); (c) **#3013/#2293 not reproduced** — awaited *and* fire-and-forget background subagents still fire `preToolUse`/`postToolUse` (and the fire-and-forget run additionally emits an `agent_completed` notification), with the OTel tree unchanged (caveat: parent-exits-before-child not exercised in `-p` mode); (d) the **cross-source join key `toolu_<taskId>`** is equal across hooks, `events.jsonl`, and OTel (sync + async), so hook spans can be enriched with the real agent name — prefer **OTel (documented) over `events.jsonl` (undocumented)**. Adds an H/E/O three-path comparison table. Measurement spike — no production code; features carry a governed `doc-only` red-first waiver. Feeds #227. _(PR #248)_

### workbook-redesign (#222): issue-run list + fleet-health tiles (Tabs 0-1)
- **#222 — the Harness Quality Workbook now monitors *issue runs*, not just by-version aggregates.** The workbook JSON is restructured into a tabbed container (a `"style":"tabs"` links item driving a `selectedTab` parameter over three conditionally-visible groups). **Tab 0 (Fleet health)** adds KPI panels over `{TimeRange}` — including first-class **in-flight run visibility** (runs seen at `worktree_create` with no `finish` span, computed with a boundary-safe `countif(started > 0 and finished == 0)` predicate), pass rate with an explicit `runs` denominator (`real(null)` over an empty window, never a fabricated 0), fleet `red_reentry_free_rate`, deviation count, and token spend with `tokens_status` honesty. **Tab 1 (Issue runs)** is a one-row-per-(issue, version) grid keyed on the mandatory `harness.issue` field (previously unused by every panel), with conditional formatting (fail=red, in-flight=blue, deviations>0=amber, null outcome=neutral) and a `{Issue}` drill-through parameter export the single-run tab (#223) will consume. **Tab 3 (Version comparison)** retains the original eight by-version panels and the deferred-metrics block verbatim. Pure KQL over already-shipped allowlisted keys — no exporter change. `tests/scripts/test_trace_dashboard_pack.sh` gains four red-first Tabs 0-1 legs (tab container, in-flight tile, per-issue grouping, `{Issue}` export wiring, matched against a flattened whole-query stream); `docs/evaluation/dashboards/README.md` panel→contract map is extended with a Tab column and a row per new panel; the design doc `workbook-redesign.md` lands with this PR. _(PR #248)_

### scripts-portfolio (#213): extract the 5×-duplicated trace-guard + EXIT-trap boilerplate into trace-lib (P-1)
- **#213 — the terminal lifecycle-span `EXIT`-trap boilerplate now has one home in `scripts/trace-lib.sh`.** New `trace_lifecycle_init <step> [attr_fn]` / `trace_lifecycle_arm` / `__trace_lifecycle_exit` replace the copy-pasted `trace__*_exit` trap functions in `start-issue.sh`, `create-pr.sh`, `merge-pr.sh`, and `finish-issue.sh`; each caller supplies its late-bound, script-specific attributes through a small `trace__*_attrs` callback, so emitted span shapes are byte-identical. Each inline guard shim also defines NOOP `trace_lifecycle_init`/`trace_lifecycle_arm`, keeping "a missing `trace-lib.sh` never breaks the lifecycle" true. `review-gate.sh` is intentionally left alone (its EXIT trap is command-dispatched, a genuinely different shape). A new `tests/meta/test_lifecycle_trap_no_inline_copy.sh` drift sensor (proven red-first) forbids a fresh inline copy from reappearing in the four scripts, and `docs/harness-contract.yml`'s `trace_emission` `present:` patterns were updated to the helper emission form (owner still declares its terminal step via the helper argument). _(PR #248)_

### Subagent-observability spike (#226): measure Copilot CLI hook/payload behavior for tool+skill calls inside subagents
- **#226 — a live-captured verdict now records how Copilot CLI v1.0.69 hooks behave for tool and skill calls made *inside* a subagent.** New sibling spike doc `docs/runtime-adapters/github-copilot.subagent-spike.md` (cross-referenced from `github-copilot.skill-spike.md`) answers the four unknowns with redacted, version-stamped payload excerpts: (a) `preToolUse`/`postToolUse` **do** fire inside subagents (custom + built-in `general-purpose`); (b) a subagent's tool-call payloads carry a **`toolu_`-prefixed `sessionId`** (the spawning `task` tool-use id) with **no agent field** — detectable but not attributable from hooks alone; (c) a skill invoked by a subagent surfaces as `toolName=="skill"`; (d) `subagentStart`/`subagentStop` carry the **conductor's** sessionId + `agentName` but **no child sessionId**. Bonus: `general-purpose` **emitted** the subagent events, contradicting the docs. The only source that joins a subagent span to its agent name/model is the conductor's `events.jsonl` (`agentId` / `subagent.started.toolCallId`). The verdict **corrects #227 Task 1** (bind on first `toolu_` sessionId, not at `subagentStart`) and records two capture paths. Measurement spike — no production code; features carry a governed `doc-only` red-first waiver. _(PR #248)_

### Skill-modernize (#202): collapse subagent repetition, single-source the handback spec, merge the planning depth table
- **#202 — the four subagent prompts are deduplicated and the handback payload spec is single-sourced.** The `[<role>] <step> <feature_id> <outcome> — <summary>` payload template + token caveat now live once in `harness.instructions.md` §3 (Agent-span conventions); each agent keeps one line naming its role and valid steps and points there. `test-subagent`'s repeated "never weaken a sensor" statements and the duplicated "do not call other subagents directly" collapse to one authoritative statement each; `code-review-subagent`'s "blocking findings first" restatements are trimmed and both worked examples removed (the output templates already specify the format). `planning-subagent` merges its "Planning Depth" and per-depth "Workflow Step 1" lists into one depth table with a shared web-research subsection (~258→170 lines). New `tests/meta/test_subagent_prompt_dedup.sh` plus the reworked `test_subagent_handback_payload.sh` and `test_planner_web_fallback.sh` sensors guard the single-source spec, the removed repetition/examples, and the depth-table structure (all proven red-first). The finding-pass vs reporting-pass split is preserved. _(PR #248)_

### Skill-modernize (#200): prune stale Taskfile references and duplicated doctrine
- **#200 — instruction files no longer reference the retired `task preflight` / `task init-issue` / `task finish-issue` Taskfile workflow, and duplicated stop/retry/feedback doctrine is deduped.** `workflow-tiers.instructions.md` replaced the stale "Optional: Issue-driven harness" Taskfile section with a generic note, genericized the init-issue step, and collapsed the repeated stop/retry/feedback rules; `harness.instructions.md` §3 tightened the non-delegable block and hoisted the Red→Green→Refactor bullet. A new `tests/meta/test_instructions_no_stale_repetition.sh` regression sensor guards against the stale phrasing and repetition (proven red-first). _(PR #209)_

### Skill-modernize (#201): single-source the product-quality rubric in the subagents
- **#201 — the four blocking gates and six-dimension scorecard now live only in `docs/evaluation/product-quality-rubric.md`.** `test-subagent.agent.md` and `code-review-subagent.agent.md` previously restated the gate definitions (twice in the reviewer) and the full 0–12 scorecard bands; they now keep only a pointer to the rubric doc, the gate/dimension **names**, and their agent-specific evidence/routing rules. The numeric score bands moved into the sensor's `test_doc` (single source), the agent band-restatement assertions were relaxed, and a new `drift` subcommand in `tests/meta/test_product_quality_rubric.sh` parses the canonical gate/dimension names from the rubric doc headings and fails if either agent drifts from them (with a 4-gate/6-dimension count guard). Proven red-first via doc gate-rename and dimension-count mutations.

### Agent Delivery Accuracy Matrix from review, outcome, and trace evidence
- **#158 — the harness now has a first-class Agent Delivery Accuracy Matrix that
  translates ML-style accuracy monitoring into coding-agent delivery quality,
  and names which signals are labels vs proxies vs degradation vs efficiency.**
  New machine-readable contract `docs/evaluation/agent-delivery-accuracy-matrix.v1.json`
  (20 metrics across four layers — `direct_label`, `proxy_label`,
  `degradation_signal`, `efficiency_after_quality`); every metric carries an
  explicit `numerator`, `denominator`, `source`, `coverage_required`,
  `absence_semantics`, `blocking_policy`, and `goodhart_guard`. Companion doc
  `docs/evaluation/agent-delivery-accuracy-matrix.md` defines agent-delivery
  accuracy as **distinct** from merge completion (`merged` = delivery completed,
  not correct), test pass, trajectory quality, and cost efficiency; references
  the seven existing contracts (`trace-summary.v1.json`, `trace-report.sh --all` markdown,
  `evaluation-matrix.md`, `outcome-evals.md`, `product-quality-rubric.md`,
  `trajectory-evals.md`, `cost-efficiency-evals.md`); states the anti-Goodhart
  rule (lower cost / higher merge rate cannot offset correctness/review/security/
  trace/lifecycle regressions); labels deferred metrics honestly
  (`post_merge_bug_rate`, `review_blocking_finding_rate`, token/cost — never
  fabricated zeros); and records the finish-vs-`pr_merge` attribution-window
  distinction. `docs/evaluation/dashboards/README.md` gains a matrix panel→layer
  mapping note (which panels map to which layer, which metrics are deferred).
  Two deterministic sensors: `tests/meta/test_agent_delivery_accuracy_matrix_contract.sh`
  (fails if any metric lacks a non-empty denominator OR absence_semantics, or if
  a layer is missing) and `tests/meta/test_agent_delivery_accuracy_matrix_doc.sh`
  (docs-content).

### Genericize extracted product references in instruction files
- **#199 — Azure AI Foundry / Content Understanding extraction residue removed from the reusable instruction files.** `harness`, `tdd`, and `python` instructions now speak of "the external service boundary", "the model/service client", and secrets-from-env without naming the extracted product; the Azure-scoped `terraform-azure` file drops the specific Foundry/CU coupling and the "1-week POC" assumption and trims ~46 lines of generic Terraform ceremony a modern model already knows, keeping the real policy (azapi for uncovered resources, `prevent_destroy` on data stores, the data-agreement destroy rule). `REQUIRE_AZ` and every genericized principle are preserved; the only remaining product nouns are explicitly-marked `e.g.` examples. New sensor `tests/meta/test_instructions_product_generic.sh` fails if unmarked residue reappears.

### Land `.copilot/` full health-check report
- **Point-in-time `.copilot/` review brought into the repo.** `docs/copilot-health-check.md` (rolls up the skills + subagents reviews and adds the first `instructions/`+`prompts/` review — findings C-1..C-4) was previously an untracked working file; it is now tracked so the `Report:` citations in the follow-up issues #199 and #200 resolve to a stable in-repo source.

### code-review-subagent reads the trace as first-class evidence (Trace / Process Evidence section)
- **#156 — every code review now includes a required Trace / Process Evidence
  section that judges delivery discipline from the local trace, not just the diff.**
  `.copilot/agents/code-review-subagent.agent.md` gains a `## Trace / Process
  Evidence` section instructing the reviewer to locate `trace.jsonl` /
  `trace-summary.json`, run `scripts/check-trace-consistency.sh NN` when a local
  trace exists, and report
  trace **coverage** separately from behavior (`has_tool_spans=false` = runtime
  instrumentation absent, not "no tools ran"; `tokens=null` = unavailable, not
  zero cost; schema pass/fail; run outcome). It encodes the evidence-authority
  split — role-attributed handback **agent** spans are authoritative for
  red-first evidence, runtime **tool** spans are corroborating only — and checks
  `red_handback → impl_handback → green_handback` ordering, role attribution
  (`test-subagent` red/green, `implementation-subagent` impl), unexplained
  `red_reentry`, deviations, and loop anomalies. Blocking findings
  (`red_first_evidence_missing`, `red_first_role_mismatch`, schema/redaction
  failure, unresolved deviations) feed `NEEDS_REVISION`/`BLOCKED` even when the
  diff is clean; missing instrumentation is reported as the exact phrase
  `trace evidence unavailable`, never inferred as pass. The section states
  passing trace discipline does not prove correctness and clean code does not
  excuse a process violation. Sensed by a new prompt-content sensor
  `tests/meta/test_code_review_trace_evidence.sh`; AC7's blocking guarantee is
  already locked by `tests/scripts/test_trace_red_first_evidence.sh`, which pins
  that `check-trace-consistency.sh` produces exactly those two findings for
  green-only and wrong-role traces.


- **#175 — teardown now sweeps orphaned runtime state, and re-running the
  transcript reconstruction no longer double-counts tool calls.**
  `scripts/finish-issue.sh` gains a warn-only `best_effort_state_hygiene()` step
  (runs after the closeout reconstruct) that removes the finished issue's
  `.copilot-tracking/issues/issue-NN/.hook-state/` dir (orphaned PreToolUse
  duration state left when a matching PostToolUse never arrived) and expires
  session bindings under `.copilot-tracking/sessions/` whose content equals the
  finished issue number (deterministic issue-scoped policy — bindings for other
  issues are left intact). Hygiene failures never change finish-issue's exit code
  or block teardown. `scripts/trace-reconstruct.sh` is now **idempotent**: each
  reconstructed tool span carries `harness.tool_call_id` (the transcript's
  `data.toolCallId`), and a second run skips any `(harness.session_id,
  harness.tool_call_id)` already present in the issue trace, appending zero new
  spans (within-run duplicates collapse too). A pair with no usable toolCallId is
  skipped with a WARN, never dedup-by-guess (omit-never-fake). The window filter
  excludes already-reconstructed tool spans so reruns can't drift the window.
  `docs/evaluation/trace-schema.v1.json` documents `harness.tool_call_id`
  additively in `.optional_fields` (open-world; not required, dropped from OTLP
  export); the reconstruct header and `observability-and-trace-schema.md` document
  the idempotency contract. Sensors: NEW
  `tests/scripts/test_finish_issue_state_hygiene.sh` proves the issue-scoped sweep
  (orphaned state + same-issue binding removed, other-issue binding survives,
  finish still exits 0); `tests/scripts/test_trace_reconstruct.sh` case 6 runs the
  reconstruction twice and asserts span-count stability + a non-empty
  `harness.tool_call_id` on every reconstructed span.

### Deep-trace: parent_span_id linking for runtime model spans (trace tree, not flat list)
- **#174 — the Stop-event model span is now parent-linked to its agent span, and
  the parent-linking policy + trace identity are decided and documented.**
  `scripts/trace-lib.sh` `trace_span` now exposes the span_id it wrote via a new
  global `TRACE_LAST_SPAN_ID` (set on a successful append, cleared to `""` on
  every drop path), so a caller can parent a following span to it without
  re-parsing the trace. Both runtime stop hooks
  (`scripts/claude-code-trace-hook.sh`, `scripts/copilot-trace-hook.sh`) capture
  that id right after emitting the agent span and add
  `parent_span_id=<agent span_id>` to the model span — **omit, never fake**: when
  the agent span was dropped the model span stays flat. Tool spans and
  `trace-reconstruct.sh` spans deliberately omit `parent_span_id` because no
  deterministic in-window parent exists at emission time (the Stop-time agent
  span does not exist when tools run); reconstruct now also `unset`s any inherited
  `TRACE_PARENT_SPAN_ID` so the omit contract is environment-independent. Decision:
  a per-run `trace_id` is **rejected** in schema v1 (spans are scoped by
  `harness.issue`, linked by `span_id`/`parent_span_id`); the OTLP export-time
  `traceId` fabrication from `harness.issue` stays the single source. Documented in
  a new "Span Linkage And Trace Identity" section of
  `docs/evaluation/observability-and-trace-schema.md`. Sensors:
  `test_claude_hook_stop_span.sh` / `test_copilot_hook_stop_span.sh` assert
  `model.parent_span_id == agent.span_id` by equality; `test_trace_lib.sh` covers
  the `TRACE_LAST_SPAN_ID` set/clear contract; `test_trace_reconstruct.sh`
  non-vacuously locks reconstructed-span parent absence.

### Land subagent-prompt-modernization review report
- **Companion review report brought into the repo.** `docs/subagent-prompt-modernization-review.md` (the `.copilot/agents/` counterpart to `docs/skill-prompt-modernization-review.md`, epic #176) was previously an untracked working file; it is now tracked so the A-X1..A-X6 findings referenced by the subagent-modernization follow-ups (#182/#183/#184) have a stable in-repo source.

### Skill-prompt modernization — strip anti-derailment scaffolding
- **#180 — old-model recovery scaffolding and command recipes were removed from audit skills.** `dead-code-detection` drops its tool-retry/path-hallucination/YAML-parser step while retaining reproducible command capture and public-API Defer-protect; `sync-docs` removes generic inventory recipes and false-positive warnings while preserving tiers, live-probe rules, high-rot claims, fix guidance, reporting, and completion criteria. The three `find-*` audit skills keep Common Search Seed categories as prose but no longer carry literal regex alternation recipe lines, and `find-over-design` no longer duplicates its pattern table. New sensor `tests/meta/test_no_antiderailment_scaffolding.sh` guards the cleanup.

### create-pr codifies repo PR conventions
- **#181 — the `create-pr` skill now encodes this repo's issue-driven harness
  conventions instead of generic PR advice.** Branch naming
  `feature/issue-<NN>-<slug>` (via `scripts/start-issue.sh`), issue-scoped
  Conventional Commit scope `feat(#NN)`/`fix(#NN)` (component scope otherwise),
  the HEAD-bound `review-gate.sh approve` + `docs/PROGRESS.md` status-doc
  requirement, PR creation through `scripts/create-pr.sh`, and the CI-green
  squash-merge discipline through `scripts/merge-pr.sh` (no standing
  auto-merge). New sensor `tests/meta/test_create_pr_conventions.sh` guards the
  conventions and blocks a revert to the generic `<type>/<short-description>`
  advice or `git add -A`.

### Trace report: distinguish bounded-by-pr-merge from unfinished runs
- **#170 — the run summary now separates a bounded trace from a truly open
  one.** `scripts/trace-report.sh` emits two additive, v1.x-compatible summary
  fields: `bounded` (true iff any `finish` OR `pr_merge` lifecycle span exists)
  and `closed_by` (`"finish"` when a finish span exists, else `"pr_merge"`, else
  `null`; finish takes precedence). The markdown final-outcome line stops
  calling a `pr_merge`-closed trace an "unfinished run" — it now states the
  final outcome is unavailable from a finish span but the attribution window is
  bounded by the `pr_merge` close edge (ref #165), with a distinct wording for a
  genuinely open/unbounded run. Existing `finished`/`final_outcome` semantics are
  unchanged (finish-only). `docs/evaluation/trace-summary.v1.json` documents the
  additive fields without adding them to `required_top_level`. New regression
  sensor `tests/scripts/test_trace_report_bounded.sh` proves all three cases
  (finish, pr_merge-only, neither) on JSON + markdown; `test_trace_report_summary_json.sh`
  now locks `bounded==true`/`closed_by=="finish"` on the core fixture.

### Skill audit conventions single-source
- **#179 — shared audit-skill boilerplate is now single-sourced.** The four
  audit skills (`find-brute-force`, `find-duplicates`, `find-over-design`, and
  `dead-code-detection`) now reference `.copilot/skills/_audit-conventions.md`
  for common exclusions, search-broadly/judge-narrowly guidance, compact
  implementation-usefulness vocabulary, report shape, and remediation-plan
  expectations. The duplicated 5-dimension H/M/L rubrics and three remediation
  plan templates were removed, while `dead-code-detection` keeps its public-API
  Defer-protect default. New sensor `tests/meta/test_audit_conventions_shared.sh`
  guards the extraction and public-exposure audit now uses the shared
  Fix-now/Plan-first/Defer-accept vocabulary.

### Skill-prompt modernization — imported-skill replacement (epic #176)
- **#178 — rewrite the imported generic `security-audit`; trim `code-review`
  worked examples.** Replaced `security-audit` (imported wholesale from
  awesome-ai-agent-skills — fabricated cloud/web findings, mandated absent
  scanners, deployed-app scope) with a ~36-line repo-scoped skill: shell/CI
  script injection, GitHub Actions workflow permissions, dependency/action
  pinning, and secrets handling, built-in-tools-first with scanners optional.
  Cut both fabricated worked examples (~115 lines) from `code-review`, keeping
  the 6-step workflow, checklist, Critical/Warning/Info vocabulary, reviewer
  etiquette, and edge cases. New sensor
  `tests/meta/test_imported_skills_repo_scoped.sh` pins both against re-import.

### Trace schema single-source: numeric-key/role enum authority + drift sensor
- **#173 — schema-derived enums are now single-sourced in the frozen contract
  and drift-guarded.** `docs/evaluation/trace-schema.v1.json` gains additive,
  open-world arrays — `numeric_keys` (the five #103 trace-gate count keys),
  `numeric_key_prefixes` (`gen_ai.usage.`), `structural_numeric_keys`
  (`harness.issue`, `schema_version`), and `roles` (the five closed
  log-handback/consistency roles) — as the single authority for values that
  were previously hand-copied into script bodies with "keep in step" comments.
  The script-local copies in `trace-lib.sh` (numeric typing + span-type case),
  `check-trace-consistency.sh` (`$numeric_keys` and `$roles`) and
  `log-handback.sh` (role `case`) are wrapped in
  `# >>> trace-schema:<name> … # <<< trace-schema:<name>` sentinel markers and
  enforced by a new meta drift sensor
  `tests/meta/test_trace_schema_single_source.sh`, which fails set-equivalence
  when any copy drifts (proven non-vacuous by mutation). `test_trace_schema.sh`
  now locks the new arrays with hardcoded backstops. No change to existing v1
  required-field/enum semantics (frozen-contract discipline preserved); numeric
  typing verified end-to-end.

### Skill-modernize (#176): single-source the subagent routing map
- **#182 — profile-aware routing map is single-sourced and matches reality.** The
  ~12–15 line extension→language routing map that was copy-pasted into all four
  `.copilot/agents/*-subagent.agent.md` is collapsed to a one-line reference to the
  single source in `.copilot/instructions/harness.instructions.md`. That map now
  routes the two instruction files the repo actually has and previously omitted:
  `.sh` → `bash` and `.tf`/`.bicep` → `terraform-azure`. New drift sensor
  `tests/meta/test_routing_map_drift.sh` fails if any language `*.instructions.md`
  on disk is unreachable from the map or if the map names a nonexistent file (#173
  pattern); `tests/meta/test_subagent_profile_instructions.sh` rewritten to assert
  the single-source structure. Full sensor suite + L0 + shellcheck green.

### Skill-prompt modernization — cleanup (epic #176)
- **#177 — remove obsolete `general` skill, fix `create-pr` dead references,
  normalize frontmatter.** Deleted the obsolete `general` skill (training-data
  platitudes) and repointed its 8 fallback references to the harness contract +
  AGENTS.md conventions. Fixed the `create-pr` bug (dead `skills/typescript|python|testing`
  quality-gate refs → existing `code-review`/`security-audit`), trimmed its git
  tutorial and baked-in best practices. Normalized `code-review` frontmatter to
  kebab-case and dropped imported license/author metadata. Landed the grounding
  report `docs/skill-prompt-modernization-review.md`. New sensor
  `tests/meta/test_skill_references_resolve.sh` guards against dead skill refs.

### Trace docs: skill-span (`harness.skill.name`) preconditions and limits
- **#168 — documented exactly when a `harness.skill.name` skill span can and
  cannot exist.** `docs/runtime-adapters/github-copilot.md` gains a section
  pinning the two preconditions (fixed hook installed on `main` + seeded into
  the worktree; a *fresh* runtime session that surfaces the skill as a
  `toolName="skill"` tool span), the **no-backfill** limit, the
  `review_verdict` agent span vs `harness.skill.name` skill span distinction,
  the `jq` + `trace-report.sh` verification commands, and the omit-never-fake
  honesty rule for absence. Per the review note, `toolName="skill"` is framed
  as repo-owned empirical evidence (#121/#138 capture), **not** an official
  Copilot contract, and the VS Code surface as empirical/preview. Cross-linked
  from `docs/HARNESS.md`. Sensor `tests/scripts/test_copilot_adapter_docs.sh`
  extended with a D9 block. Docs-only (`red_first_waiver`).

### Trace docs drift: honest token labels + complete PII exclusion list
- **#171 — dashboards token labels de-#96'd; retention exclusion list completed.**
  `docs/evaluation/dashboards/README.md` and the workbook token panel
  (`infra/terraform/harness-quality.workbook.json`) no longer point at the
  closed #96 as the token-gap blocker: tokens are *measured when an adapter
  emits `gen_ai.usage.*`* (the Claude Code hook does), rendered as an honest
  `tokens_status = unavailable` null when absent, and the honest remaining gap
  is Copilot-side capture tracked in **#163**. `docs/evaluation/telemetry-retention-pii.md`
  now lists all **five** by-name allowlist exclusions — `harness.result_summary`
  was added to match `docs/runtime-adapters/otlp-azure-monitor.md` and
  `trace-schema.v1.json`. Sensors extended: `test_trace_dashboard_pack.sh`
  asserts no stale `until #96` and a `#163` pointer; `test_telemetry_retention_docs.sh`
  asserts the full 5-field exclusion list. Docs-only; full suite 119/0.
### Trace redaction: close secret-shape gaps + single-source the backstop
- **#172 — `trace_redact` masks four more secret shapes; secret-shape backstop
  single-sourced.** `scripts/trace-lib.sh` `trace_redact` now masks bare JWTs
  (`eyJ` + three dot-separated base64url segments, length-floored), Azure SAS
  `sig=` query values, storage `AccountKey=` values (key kept, value masked),
  and escaped PEM `PRIVATE KEY` blocks (block-local `[^-]*` body so co-located
  blocks/fields can never greedily merge). Portable BSD/GNU sed -E and the
  JSON-safety invariant (never truncate an unquoted number / break a line) are
  preserved. The hardcoded secret-shape audit backstop is now single-sourced as
  `TRACE_SECRET_SHAPE_RE` in `trace-lib.sh`; `trace-export.sh` and
  `sanitize-trace.sh` (both audit sites) reference it instead of forked
  literals. Generic `sig=`/`AccountKey=` shapes are intentionally excluded from
  the backstop because their redacted form (`sig=[REDACTED]`) would self-match.
  Sensors: `tests/scripts/test_trace_lib_redaction.sh` gains a fixture per new
  shape (incl. a two-PEM-block JSON-safety case); new
  `tests/scripts/test_trace_backstop_single_source.sh` drift sensor pins the
  consumers to the shared source. Full shell suite 120/0, shellcheck clean.

### Deep-trace native OTLP export
- **#151 — opt-in native OTLP/HTTP export alongside the Track API path.**
  `scripts/trace-export.sh` gains a second, independent transport that ships
  schema-v1 spans as native wire-OTLP (OTLP/HTTP + JSON) to any OTel backend,
  without touching the existing Application Insights Track API path. New
  `--dry-run-otlp-to-file` seam maps each span to an OTLP `resourceSpans` object
  (per-issue `traceId`, `span_id`/`parent_span_id` → span/parent linkage, kind
  INTERNAL, `startTimeUnixNano`/`endTimeUnixNano` with honest single-point
  `end==start` — no fabricated durations, the same 26-key allowlist projection).
  The SAME fail-closed `redaction_gate` (Gate 1 input + Gate 2 fixed-point /
  hardcoded secret-shape backstop / excluded-field belt, made shape-aware for
  OTLP `stringValue`s) guards the OTLP body before it leaves. Live transport is
  opt-in via `TRACE_EXPORT_OTLP_HTTP=1` + `OTEL_EXPORTER_OTLP_ENDPOINT`
  (`/OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`), one `application/json` POST to
  `/v1/traces`; `OTEL_EXPORTER_OTLP_HEADERS` carries auth and is never logged /
  committed / echoed. Both transports default-off and independently selectable;
  setting both ships both. Frozen in `docs/harness-contract.yml`
  (`TRACE_EXPORT_OTLP_HTTP` env-flag, owner `trace-export.sh`); documented in
  `docs/runtime-adapters/otlp-azure-monitor.md`. Sensors:
  `test_trace_export_otlp_mapping.sh`, `test_trace_export_otlp_redaction.sh`,
  `test_trace_export_otlp_transport.sh`, `test_trace_export_docs.sh` (D9).

### Deep-trace interval attribution
- **#165 — sessionId→issue binding + guaranteed interval-window closure.**
  Hardens the #146/#164 attribution so the VS Code conductor topology (cwd =
  main checkout on `main`, git resolves nothing) never mis-attributes a
  tool/skill span when two issue windows overlap. **AC1 — session binding:**
  `scripts/copilot-trace-hook.sh` now keeps a per-session `sessionId → issue`
  map, one file per session under
  `${main_checkout}/.copilot-tracking/sessions/<sessionId>` (content = unpadded
  issue number). It **writes** the binding whenever git resolves an issue for a
  session (it then knows both `sessionId` and issue), and on the main-checkout
  path where git resolves nothing it **reads** the binding first: a hit
  attributes the span by exact key lookup and skips interval entirely. Effective
  precedence is **git → binding → interval** — git stays authoritative and always
  first (CLI-from-worktree unchanged, zero regression), the recorded binding
  removes the *need* to guess only when git is blind, and a stale binding is
  refreshed to the git issue on every git-resolve (never overrides an unambiguous
  git resolution). `sessionId` is sanitized (`^[A-Za-z0-9._-]+$`, rejects `.`/`..`)
  and the read-back issue validated `^[0-9]+$` — no path traversal. **AC2 —
  guaranteed closure:** the interval window close is now `LATEST{finish, pr_merge}`
  (was `finish` only), so because `merge-pr` is the reliable merge gate that
  always runs, a **merged**-but-unfinished issue is bounded at the merge instead
  of staying open-ended and leaking later spans. Session-safety (exit 0 +
  empty stdout) preserved on every path. Sensors:
  `test_copilot_hook_session_binding.sh` (B1–B5: bound-beats-overlap, binding
  written on git path, no-binding→interval preserved, garbage binding ignored,
  git-beats-stale-binding + refresh), `test_copilot_hook_interval_attribution.sh`
  (new **C8** pr_merge-close edge, C1–C7 unweakened),
  `test_interval_attribution_docs.sh` (concept 6 binding precedence + concept 7
  pr_merge close); docs in `docs/runtime-adapters/github-copilot.md`.
  Follow-up to #146. The official GitHub Copilot hooks reference documents two
  payload dialects with **different `timestamp` types**: the real CLI (camelCase,
  e.g. `postToolUse`) sends a JSON **number** of Unix epoch **milliseconds**,
  while the VS Code dialect sends an ISO-8601 **string**. `hook__resolve_issue_by_interval`
  compared the raw timestamp **lexicographically** against ISO-8601 `…Z` window
  bounds, so an epoch-ms number (`"1783438703222"`) never matched any window →
  **every CLI tool/skill span from the main-checkout topology was silently
  dropped**. Fix: a new `hook__ts_to_iso` helper normalizes only the incoming
  timestamp before comparison — all-digit epoch-ms → floor to whole seconds →
  UTC ISO (BSD `date -r` / GNU `date -d @`); an ISO/non-digit string passes
  through unchanged; empty/unparseable → `return 1` into the existing warn+drop
  leg (never fabricates a timestamp, never `now()`). Window bounds, the git-first
  path, and the C4 ambiguity contract are untouched; session-safety (exit 0 +
  empty stdout) is preserved on every path including a `date` failure. Sensor:
  new case **C7** (camelCase epoch-ms interval hit) in
  `test_copilot_hook_interval_attribution.sh` — RED before the fix, GREEN after,
  with C1–C6 unweakened.
- **#146 — interval (session_id + time) attribution for runtime tool/skill
  spans.** Closes the "no tool/skill spans" gap for the VS Code conductor
  topology. Verified first (see the #146 comment) that VS Code agent hooks DO
  fire, but the payload `cwd` is always the **main checkout on `main`**, so the
  git-based `trace__resolve_issue` resolves nothing and the hook silently
  no-opped. `scripts/copilot-trace-hook.sh` now: (1) stamps `harness.session_id`
  (#147) on every emitted tool/agent span in both payload dialects; and (2) uses
  **git-first, interval-fallback** attribution — when git resolves nothing, it
  attributes each span by the payload `timestamp` to the single issue whose
  active window `[worktree_create, finish]` (derived from the lifecycle spans
  already in each `.copilot-tracking/issues/issue-NN/trace.jsonl`, open-ended
  when unfinished) contains it. Zero/ambiguous windows or a missing timestamp →
  visible WARN + no-op; never mis-attributes, never fabricates; the hook stays
  exit-0 / stdout-clean on every path. Git resolution stays the fallback for
  CLI-from-worktree (zero regression). The obligation is frozen in
  `docs/harness-contract.yml` (owner `copilot-trace-hook.sh`). Sensors:
  `test_copilot_hook_session_id.sh`, `test_copilot_hook_interval_attribution.sh`
  (C1-C6) + e2e `test_copilot_hook_interval_e2e.sh`,
  `test_interval_attribution_docs.sh`; docs in
  `docs/runtime-adapters/github-copilot.md`. (The requested start-issue
  hook-seeding fold-in was dropped — origin/main already seeds the hook and the
  Terraform-seed variant would violate the frozen `language_neutral` contract.)

### Deep-trace transcript reconstruction
- **#149 — reconstruct tool/skill spans from the Copilot transcript at
  closeout.** Added `scripts/trace-reconstruct.sh <issue-number>`: it resolves
  the main-root issue trace, computes the `[min,max]` timestamp window of the
  existing harness spans, scans the Copilot per-session transcript
  (`COPILOT_TRANSCRIPTS_DIR` override, default real `workspaceStorage` glob),
  pairs `tool.execution_start`/`tool.execution_complete` by `toolCallId`, keeps
  only in-window pairs, and emits tool spans through `trace-lib`'s `trace_span`
  (`gen_ai.tool.name`, `harness.duration_ms`, `harness.outcome`,
  `harness.session_id`) — never emitting raw tool arguments (no leak).
  Best-effort and warn-only: exit 0 when the transcript dir is absent, exit 2
  only on usage/env error. `scripts/finish-issue.sh` now invokes it
  unconditionally best-effort at closeout (`best_effort_trace_reconstruct`:
  always returns 0, warn-skips when the script is absent, warns-and-continues on
  failure) — teardown is never blocked. This closes the "no tool/skill spans"
  gap for the VS Code conductor topology by recovering spans the live hooks
  miss. Sensors: `test_trace_reconstruct.sh`, `test_finish_issue_reconstruct.sh`.

### Harness versioning
- **#153 — SemVer harness version; decouple `harness.version` from
  `harness.commit`.** Introduced a top-level `VERSION` file (SemVer, seeded
  `0.1.0`) as the authoritative harness release version. `scripts/trace-lib.sh`
  now stamps `harness.version` from `VERSION` (fallback `0.0.0-dev`) instead of
  the git short SHA — so it is **stable across commits** and `by_version`
  aggregation is finally meaningful — and adds a new optional `harness.commit`
  (short SHA) for exact provenance. Schema + observability docs updated;
  `docs/HARNESS.md` documents the manual bump policy (bump only on
  behaviour/contract changes; docs/test-only commits do not bump; the
  contract-schema `version:` is separate). Backward compatible (old SHA-valued
  traces still validate). Sensor: `test_harness_versioning.sh`;
  `test_trace_lib.sh` reconciled to the new semantics.

### Deep-trace session identity
- **#147 — add optional `harness.session_id` to the trace schema.** Additive,
  open-world schema field (string; runtime/conversation session identity aligned
  with OTel `gen_ai.conversation.id`), documented in
  `observability-and-trace-schema.md`, distinct from `harness.issue` (a session
  can span multiple issues; runtime spans are attributed to an issue by time
  window). Backward compatible — spans without it still validate; key-coverage
  unaffected (documented-but-not-yet-emitted is allowed). Foundation for the
  runtime tool/skill capture line (#149/#146). Sensor:
  `test_trace_schema_session_id.sh`.

### Deep-trace runtime-signal spike
- **#148 — GitHub Copilot deep-trace signal spike.** Empirically determined what
  runtime tool/skill/model signals GitHub Copilot exposes per surface, to steer
  the tool/skill observability line (#146/#149/#150). Key findings (see
  `docs/runtime-adapters/github-copilot.trace-spike.md`): (1) VS Code agent-mode
  hooks are Preview and a mid-session probe captured nothing — inconclusive,
  needs a fresh-session test; (2) Copilot writes a structured per-session
  transcript to disk at `GitHub.copilot-chat/transcripts/<session_id>.jsonl` with
  `tool.execution_start`/`tool.execution_complete` events paired by `toolCallId`
  (so tool latency + success are recoverable — richer than the correlation-id-less
  live hook); (3) per-turn token usage is cloud-DuckDB `events` only
  (`chat.sessionSync.enabled`), local `models.json` is just a catalog; (4)
  `session_id` is the universal join key. Recommendation: closeout transcript
  reconstruction (#149) is the primary path for VS Code; live-hook interval
  attribution (#146) is mainly for CLI; token/cost (#150) is cloud-only. Sensor:
  `test_trace_spike_docs.sh` pins the findings.

### Deep-trace evidence & closeout export
- **#144 — enforce reliable evidence capture and closeout export.** Closed two
  silent-failure modes in the deep-trace pipeline by moving telemetry guarantees
  onto non-optional script paths and freezing them in the contract. Six features,
  each with one regression sensor:
  - **Red-first evidence rule** — `check-trace-consistency.sh` now flags any
    `passes:true` feature lacking a role-correct, file-ordered
    `test-subagent red_handback → implementation-subagent impl_handback →
    test-subagent green_handback` triple (`red_first_evidence_missing`) or with a
    wrong-role handback (`red_first_role_mismatch`), unless the feature carries a
    governed structured `red_first_waiver` (`kind` ∈ bootstrap/visual-only/
    doc-only/justified, non-empty reason). Never fabricates or backfills spans
    (`test_trace_red_first_evidence.sh`).
  - **PR-path hard gate** — `review-gate.sh` `approve`/`check` hard-block by
    default on those red-first findings (a refusal, no marker written), and
    `create-pr.sh` inherits the block; the broader trace gate stays warn-only
    (`test_red_first_pr_gate.sh`).
  - **Worktree hook seeding** — `start-issue.sh` copies a developer-local
    `.github/hooks/harness-trace.json` from the main checkout into a freshly
    created worktree when present, skips cleanly when absent, and never clobbers
    a reused worktree (`test_issue_scaffold.sh`).
  - **Best-effort closeout export** — `finish-issue.sh` attempts
    `trace-export.sh` after worktree removal only when `TRACE_EXPORT_OTLP=1` and
    `APPLICATIONINSIGHTS_CONNECTION_STRING` are set; a clean no-op otherwise and
    warn-and-continue on failure, never blocking teardown
    (`test_finish_issue_trace_export.sh`).
  - **Docs** — the evidence authority split (handback `agent` spans as accepted
    red-first proof vs. runtime hook `tool` spans that need deterministic
    per-feature attribution before counting), hook seeding, closeout export, and
    the unregistered-named-subagent fallback are documented across `HARNESS.md`,
    `observability-and-trace-schema.md`, and the Copilot/OTLP adapters
    (`test_trace_authority_docs.sh`).
  - **Contract freeze** — `docs/harness-contract.yml` declares `trace-export.sh`,
    the `local-hook-seeding` and `trace-export` lifecycle obligations, the
    `TRACE_EXPORT_OTLP` flag, the `pr-path-red-first-gate`, and the
    `missing-red-first-evidence` / `wrong-red-first-role-attribution` failure
    modes so they cannot be silently deleted (`test_harness_contract.sh`).

### L0/L1 evaluation
- **#64 — L0 manifests + blocking CI gate.** Authored the five L0 eval
  manifests (`tests/evals/manifests/scripts/l0-{harness-contract,lifecycle-order,
  review-gate,feature-list,issue-scaffold}.json`) — each `boundary:script-lifecycle`,
  its grader running the matching L0 sensor, and a `contract_refs` array whose
  every `section:id` resolves to a real `docs/harness-contract.yml` entry (no
  third source of truth). Added `tests/evals/bin/run-l0-suite.sh`: runs the 5
  manifests through `run-evals.sh`, prints case-level scorecards, and exits
  non-zero iff any case `blocking_decision==block` (scorecard-authoritative, not
  exit-code-trusting; accepts a manifest-dir arg for testability). Wired into
  `harness-smoke.yml` as a distinct blocking **Run L0 suite gate** step (no Azure
  config). Also folded in #63's deferred item: CI now lints `tests/scripts/lib/*.sh`
  under `bash -n` + `shellcheck`. Sensors: `test_l0_manifests.sh` (contract-ref
  resolution, good/bad self-checked), `test_l0_ci_gate.sh` (default-green +
  mutation block-proof + CI wiring). This completes the L0 eval workstream
  (#61–#64). Follow-up MINORs (non-blocking, from review): `require_text`
  `[^\n]*`→`.*` grep-dialect portability; `run-l0-suite.sh` runner-stderr
  passthrough; treat an unparseable scorecard as blocking (fail-closed).

- **#62 — local eval runner + case-level scorecard + fail-closed redaction gate.**
  Added `tests/evals/bin/run-evals.sh`: validates a manifest (via #61's
  `validate-manifest.sh`), runs its grader, and emits a schema-valid case-level
  scorecard JSON to stdout (per docs/evaluation/l0-solution/spec.md § Scorecard
  Schema) — reproducibility fields (commit_sha, manifest path/version,
  runner_version, tool_versions), per-case row (status/failure_type/evidence/
  observable_signal/blocking_decision/trials), and aggregates. Status mapping:
  pass→pass, non-zero grader→fail+target_failure, invalid manifest→invalid_manifest,
  missing grader dependency→not_run+environment_missing (command -v probe). A
  fail-closed redaction gate captures grader evidence, scrubs it via `trace_redact`
  plus a redactor-independent secret-shape backstop, and classifies a detected
  secret as `redaction_failure` with zero raw-secret leak on stdout/stderr.
  not_run/invalid_manifest/infrastructure_error de-escalate to
  `blocking_decision:warn` (not a Tier A block). Sensors:
  `test_run_evals_scorecard.sh` (21), `test_run_evals_not_run.sh` (6),
  `test_run_evals_redaction.sh`. Consumed by #64 (wires the runner into CI).
  Deferred MINORs: fixture_path/hash for static fixtures; env-identifier
  detection (Tier B / #67); multi-token grader command parsing.

- **#63 — case-level TAP output for the 5 L0 sensors.** Added a hand-rolled,
  dependency-free TAP emitter `tests/scripts/lib/tap.sh` (bash-3.2 compatible;
  `tap_ok`/`tap_not_ok`/`tap_is` emit one row per scenario and never `exit`;
  `tap_done` prints the `1..N` plan and returns non-zero iff any scenario
  failed — continue-past-failure). Converted the 5 L0 sensors
  (`test_harness_contract`, `test_lifecycle_order`, `test_review_gate`,
  `test_feature_list_check`, `test_issue_scaffold`) from fail-fast to
  per-scenario TAP (12/3/6/11/5 rows) using two isolation patterns
  (per-scenario subshell vs. single-shell accumulator), preserving exactly what
  each sensor exercises and its exit semantics. Sensors:
  `tests/meta/test_tap_helper.sh`, `tests/meta/test_l0_sensors_tap.sh`. Decision:
  hand-rolled TAP over `bats-core` (zero-dependency, matches repo ethos).
  No-fail-fast mutation-proven on both patterns; full suite green.
  Deferred (fold into #64, which already touches the workflow): extend the CI
  `shellcheck` glob to cover `tests/scripts/lib/*.sh`.

- **#61 — eval directory contract + manifest schema validator.** Established
  the `tests/evals/` target-first layout (`manifests/{scripts,skills}`,
  `fixtures/{scripts,skills}`, `baselines/`, alongside the existing
  `scorecards/`), each kept by a tracked `.gitkeep`. Added
  `tests/evals/bin/validate-manifest.sh` — a deterministic `jq`-based manifest
  validator enforcing the required-field set, the `boundary` enum, the
  `blocking` boolean, and the fixture `oneOf` keyed on `fixture.type`
  (generated⇒`builder`, static⇒`path`; neither/both/mismatch/non-object all
  rejected with `invalid_manifest` + a specific reason). CI (`harness-smoke.yml`)
  now lints `tests/evals/bin/*.sh` with `bash -n` + `shellcheck`. Sensors:
  `test_eval_dir_contract.sh`, `test_eval_manifest_validator.sh` (12 cases),
  plus extended `test_harness_smoke.sh`. Root of the eval framework the runner
  (#62) and L0 manifests (#64) build on. Out of scope: runner, L0 manifest
  content, L1 cases.

### Deep tracing
- **#139 — surface skill/tool usage in report, scorecard, and App Insights (C of the #121 split — completes the skill workstream).**
  With `harness.skill.name` emitted (#138), skills are now visible everywhere
  tool usage is: `trace-report.sh` emits a `skills` aggregate
  ([{name, calls, fail_calls}]) in `trace-summary.json`; `trace-report.sh --all`
  adds a per-bucket `skills` aggregate and per-run skills on the issue rows; the
  harness-quality workbook gains a **Skill-invocation volume** panel over
  `dependencies` sliced by `customDimensions['harness.skill.name']` (fail from
  `harness.outcome`). Both contracts documented (open-world optional); the
  dashboard-pack sensor now requires a skill panel and the dashboards README
  panel map is updated. The #121 follow-up split (A #137 → B #138 → C #139) is
  complete; D (skill-completion via the SKILL.md convention) stays deferred.
  With CLI tool spans restored by #137, the spike-confirmed `skill` tool call
  (`toolName: "skill"`, name in `toolArgs.skill`) now carries
  `harness.skill.name` — a tool-span attribute, not a first-class `skill` span
  kind (owner decision 1b). The hook parses `toolArgs.skill` (camel string or
  object; snake `tool_input.skill`) only when the tool name is `skill`; the key
  is omitted on malformed args and never appears on non-skill tools. Documented
  in `trace-schema.v1.json` (drift sensor now 32 keys) and added to the
  `trace-export` allowlist (enum-like, safe to ship). Sensors E13/E14 plus the
  #121 spike hypotheses test updated to the resolved behavior. Unblocks #139
  (surface skill usage in report/scorecard/App Insights).
  Bug-class fix from the #121 spike: CLI v1.0.69 sends **no `event` field**, so
  `copilot-trace-hook.sh` dropped every CLI tool call and emitted no tool spans
  at all (which also meant #130 `result_summary` never landed on real CLI).
  `hook__main` now infers a camel post-tool-use from shape (a non-empty
  `toolName` plus a result signal: `toolResult`, or a top-level `error`), while
  a `toolName`-less stop-shaped payload is never misclassified and the
  event-bearing VS Code/snake path is untouched. `hook__on_post_tool_use` maps
  a non-empty top-level `error` to `harness.outcome=fail` (Gap 2). Tool/model
  spans and `harness.result_summary` now actually land on the CLI surface.
  `github-copilot.md` corrected to v1.0.69 reality. Sensor cases E10 (event-less
  success + retroactive result_summary), E11 (top-level error → fail), E12
  (no `toolName` → no span). Unblocks #138 (skill identity) and #139 (surface).
- **#121 — skill-invocation observability SPIKE: DONE, issue closed, split into follow-ups.**
  The Spike-Live capture landed the answer static analysis could not give
  (`docs/runtime-adapters/github-copilot.skill-spike.md`, Copilot CLI v1.0.69):
  a skill invocation IS a first-class CLI tool call (`toolName: "skill"`, name
  in `toolArgs.skill`, success via `toolResult.resultType`, failure via a
  top-level `error`), but the capture surfaced two prerequisite gaps that make
  the current hook emit **no** CLI tool spans at all: (1) CLI v1.0.69 payloads
  carry **no `event` field**, so the hook's dispatch drops every CLI tool call
  (this also retroactively means #130 `result_summary` never landed on real
  CLI); (2) failure is a top-level `error` string, not
  `postToolUseFailure`/`resultType`. Selected path: **A primary** (represent
  the skill as a `tool` span carrying `harness.skill.name`, owner decision 1b),
  **B in reserve** (the SKILL.md → `log-skill.sh` completion-outcome convention,
  deferred). #121 is a spike and its deliverable is this finding; the work is
  split into follow-up issues to be executed in order:
  A — fix the CLI hook against real v1.0.69 payloads (event-less dispatch +
  top-level `error` outcome; bug-class, unblocks all CLI tool/model spans and
  #130); B — CLI skill identity (`harness.skill.name` from `toolArgs.skill`);
  C — surface skill/tool usage in trace-report, scorecard, App Insights;
  D (deferred) — skill-completion outcome via the SKILL.md convention.
- **#131 — telemetry-coverage in trace-summary + scorecard (P1-2).** Stops the
  cross-run scorecard from blending instrumented and lifecycle-only runs.
  `trace-report.sh` now emits `coverage {has_tool_spans, has_model_spans}` in
  `trace-summary.json` (computed from span presence; span-kind counts already
  ride `span_counts.by_type`), documented in `trace-summary.v1.json` as an
  additive open-world optional key — no `summary_schema_version` bump, absent on
  older summaries. `trace-report.sh --all` adds a per-bucket
  `tool_coverage {runs_with_tool_spans, of}` (mirroring the existing
  `token_coverage` honest-denominator pattern) and propagates per-run `coverage`
  onto the issue rows: a lifecycle-only run counts in `of` but not in
  `runs_with_tool_spans`, so a low `tool_calls` sum reads as "the adapter was
  not wired", never "the agent called nothing". A pre-#131 summary degrades to
  `null` rather than a fabricated flag. Third of the deep-trace P1 batch.
  Closed the one deep-telemetry gap where the boundary was on our side: both
  runtime hooks already RECEIVED the tool result but dropped it, keeping only
  pass/fail. Now `copilot-trace-hook.sh` sources it from
  `toolResult.textResultForLlm` (camel) / `tool_result.text_result_for_llm`
  (snake) and `claude-code-trace-hook.sh` from `tool_response` (string
  verbatim / object `tojson`), each redacted-before-cap at a dedicated
  `HOOK_RESULT_SUMMARY_CAP=500` and omitted when absent. Documented in
  `trace-schema.v1.json` (the #132 drift sensor now guards 31 keys). Treated as
  high-leakage: added to the export belt-check exclusion and kept out of the
  allowlist, with the mapping-test E3 byte-absence fixture extended and
  mutation-tested (allowlisting it makes the export refuse, fail-closed).
  Moves command outputs / test results / stack traces from "unrecorded" to
  "partial". Second of the deep-trace P1 batch (order B).
  Closed the documented-vs-emitted vocabulary drift: audited all 30
  `harness.*`/`gen_ai.*` keys emitted by `trace_span` across `scripts/` (lifecycle
  scripts + both runtime hooks) and added the 19 previously-undocumented ones to
  `trace-schema.v1.json` `optional_fields`, typed to match trace-lib serialization
  (5 numeric: `exit_status`/`duration_ms`/`incomplete_count`/`violation_count`/`warning_count`;
  the rest strings, including `pr_number`). Two new `tests/meta/` drift sensors
  guard independent directions: `test_trace_schema_key_coverage.sh` (every emitted
  key is documented) and `test_trace_export_allowlist_contract.sh` (the
  25-key export allowlist ⊆ documented contract, so no undocumented key reaches
  App Insights — mutation-tested for teeth). First of the deep-trace P1 batch
  (order B: #132 → #130 → #131 → #121).
  remote-monitoring capstone. Added a live-deployable Azure Workbook
  (`infra/terraform/workbook.tf` + `harness-quality.workbook.json`, an
  `azurerm_application_insights_workbook` attached via `source_id` to the
  module's own AI component) whose panels key on `harness.version` (the
  continuous form of the #104 scorecard): pass rate, red-reentry-free rate
  (labeled exactly that, never "first-pass green"), deviation rate, tool-call
  volume, wall-clock per lifecycle_step, failure-mode view; token/cost and the
  two deferred metrics rendered explicitly-unavailable (honest null, never a
  fabricated 0). Every query binds an explicit timespan (envelope time = source
  span timestamp). A sensor (`test_trace_dashboard_pack.sh`) lints every KQL
  key against the LIVE exporter allowlist, table correctness, timespans, and
  the honest-metrics rules. Two #112-review carry-over hardenings on the
  exporter: (1) value-length(256)+printable-charset caps on allowlisted string
  customDimensions values — fail-closed, refuse-whole-export on any violation,
  numeric/measurements exempt; (2) broadened redaction backstop + trace_redact
  for `InstrumentationKey=<guid>` (the sink's own connection-string self-leak)
  and `sk-ant-`/`sk-` API-key shapes, anchored so bare `sk-`/the word
  InstrumentationKey are not false-dropped. Plus `telemetry-retention-pii.md`
  (retention tied to Terraform `retention_in_days` 30d, allowlist-as-governance,
  deny-by-default PII posture, deletion/rollback path) and the #115 sink
  non-goal guard updated to allow the workbook while still forbidding
  monitor/alert/portal-dashboard. Sensors: `test_trace_export_value_caps.sh`,
  `test_trace_export_backstop.sh`, `test_trace_dashboard_pack.sh`,
  `test_telemetry_retention_docs.sh`. Post-merge: `terraform apply` the workbook
  to the live sink. Dual review (code + dedicated security).
- **#121 (partial) — tool-call + skill-invocation observability (Copilot),
  spike-first.** Ships the two non-gated features. `trace-report.sh` now emits an
  advisory `WARNING` when a FINISHED trace has lifecycle+agent spans but zero
  `tool` spans (Copilot hooks adapter absent → per-tool-call spans unavailable),
  so an empty Tool-calls table is never misread as "the agent called nothing"
  (advisory, exit 0; silent on in-progress, tool-present, and agentless runs;
  real span-derived four-predicate guard, stderr-only). Added the spike-finding
  artifact `docs/runtime-adapters/github-copilot.skill-spike.md` (payload-shape
  analysis, honest "skill observability not claimed either way", Path A runtime-
  hook vs Path B SKILL.md-convention trade-off with the exact 10 SKILL.md files,
  and a `TODO(human)` Spike-Live capture recipe + recommendation stub) and a
  characterization sensor (`test_copilot_hook_skill_payload_hypotheses.sh`,
  GREEN-from-start, hypothesis-only with a negative skill-span guard). Sensors:
  `test_trace_report_hook_absence_warning.sh` (RED→GREEN). **Deferred, gated on
  Spike-Live:** first-class `skill` span (`skill-span-schema`) + its surfacing
  (`skill-surface`) — the three schema files (`trace-schema.v1.json`,
  `trace-lib.sh`, `trace-export.sh`) are deliberately byte-untouched (committing
  schema before the spike is what the issue forbids). #121 remains open.
- **#112 — OTLP / Azure Monitor exporter adapter.**
  `scripts/trace-export.sh` ships a completed trace to Application
  Insights via the Track API (honest framing: App-Insights-native
  envelopes carrying OTel attribute names, not wire-OTLP — native OTLP
  would need a DCE/DCR + Entra resource). Opt-in (`TRACE_EXPORT_OTLP=1` +
  env connection string from the #115 Terraform output), zero core
  coupling, deny-by-default allowlist (free-text/path fields excluded
  byte-absent), fail-closed redaction gates (input validate-trace pass
  with invalid_json-only tolerance + staged-envelope audit with a backstop
  independent of trace_redact), and a `--dry-run-to-file` CI seam so no
  test touches the network. The instrumentation key never reaches process
  argv or logs; staging is mode-700. Passed a dedicated security review
  (0 blocking). Live smoke: issue-96's 39 spans shipped 39/39 accepted,
  verified arriving in the real sink via KQL, sliceable by `harness.version`.
- **#114 — GitHub Copilot primary runtime adapter.**
  The spike overturned the issue premise: Copilot now ships lifecycle
  hooks on three surfaces (CLI, VS Code agent mode Preview with
  Claude-compatible payloads, cloud agent). `scripts/copilot-trace-hook.sh`
  emits dual-dialect tool spans (object- and string-typed toolArgs,
  redact-before-cap) and stop-event agent spans plus an all-or-nothing CLI
  model span from the session events.jsonl (latest complete metrics wins;
  internal-format caveat documented). Honest gaps declared, not papered
  over: no correlation id so duration is omitted; VS Code tokens
  unavailable in v1. preToolUse is never registered — on Copilot a
  non-zero hook denies the tool call, so exit-0 containment is a safety
  property (adversarially audited). github-copilot.md is the primary
  guide; claude-code.md is reframed as the labeled reference example.
- **#115 — Terraform for the Application Insights telemetry sink.**
  `infra/terraform/`: in-stack resource group + Log Analytics workspace +
  workspace-based Application Insights; retention/sampling/daily-cap as
  validated variables (fail-fast at plan time, single cap knob wired to
  both resources); connection string only as a sensitive output consumed
  via env by the #112 exporter; remote state documented never committed;
  the full HashiCorp leak surface (state, tfvars, backend config, plan
  files, crash logs, overrides) gitignored without swallowing the
  committed lock file. Security-review gated; terraform validate passes;
  four static sensors + an honest fmt gate that skips when terraform is
  absent in CI.
- **#104 — Cross-run scorecard keyed by harness version (workstream capstone).**
  `scripts/trace-report.sh --all` aggregates per-issue trace summaries into
  `trace-report.sh --all` markdown (frozen
  `trace-report.sh --all` markdown contract, gitignored artifact, byte-identical
  reruns) with honest attribution (single version direct; multi-version by
  the trace's last version-carrying span — the sorted summary list cannot
  recover last-seen; unattributable runs land in a visible mixed bucket)
  and honest metrics (token coverage denominators, n/a never 0,
  red-reentry-free explicitly not "first-pass green", deferred metrics
  declared not fabricated; #62 mapping documented, not forked). The
  capstone dogfood produced the first full comparison table: 8 traced runs
  across 8 harness versions.
- **#103 — Trace consistency checker + two-phase gate.**
  `scripts/check-trace-consistency.sh` lifts the #95 trace↔Action-Log
  multiset detector (parity sensor-held to the meta oracle) and adds
  unverified_feature_pass, marker-only review_sha_mismatch, and
  pr_mismatch with scan-and-skip NOTEs; issue-mode resolution falls back
  to the worktree tracking dir so the checks bite on real layouts.
  `review-gate.sh trace` wraps validator + checker into the lifecycle:
  warn-only default, blocking under REQUIRE_TRACE_CONSISTENCY=1 (finish
  refuses before teardown, worktree intact), and the gate traces itself.
  The validator was rebuilt single-pass first (1 jq fork vs ~5/line) with
  the distinct redaction_audit_error rule — closing all #97 carry-overs.
- **#99 — Failure-mode taxonomy + first replay fixture.**
  Eight failure modes frozen as a closed enum in schema v1 (optional
  `harness.failure_mode`), prose authority with real workstream anchors and
  the human-gated governance stance; `TRACE_FAILURE_MODE` passthrough on
  handback spans (contract-read enum, fallback parity sensor-pinned);
  `failure_mode_violation` validator rule; `scripts/sanitize-trace.sh`
  (decode-aware path scrub, fail-closed audits) turned the real issue-97
  trace into the first committed replay fixture (37 spans incl. a genuine
  deviation, human-reviewed, provenance recorded); failure-review ritual
  template closes the human-run observe→diagnose loop. Non-goals restated:
  no automated harness mutation.
- **#98 — Per-issue trace report (`scripts/trace-report.sh`).**
  JSON-first: one jq pass builds the versioned summary object
  (`trace-summary.v1`, emitted idempotently beside the trace as the #104
  input), markdown renders from it so the two views cannot disagree.
  Two labeled clocks, per-stage/tool tables (null vs measured-zero
  discipline), deterministic loop indicators (volatile-five identity —
  mid-run harness upgrades neither hide bursts nor duplicate signatures),
  RED re-entry and deviation rollups, honest token aggregation (model
  spans only, null over fabricated zeros). Never gates: exit 0/2, never 1.
  Dogfooded on the real issue-96/97 traces.
- **#97 — Report-only trace validator (`scripts/validate-trace.sh`).**
  Lifts the #92 contract filter byte-for-byte and adds what it couldn't
  check: a known-key value-type map (string token counts / banana-typed
  schema_version now rejected), finish-gated lifecycle completeness across
  all span types, a per-line redaction audit with `trace_redact` as the
  sole oracle (fail-closed, findings never echo content), exit-neutral
  sanity warnings (`jq_skipped_pass`, unexpected location) and the
  `harness.warning=jq_skipped` honesty attr in check-feature-list. Exit
  0/1/2; gate wiring deferred to #103. Dogfooded against the real
  issue-96 (finished, 39 spans) and issue-97 traces — both validate clean.
- **#96 — Opt-in Claude Code runtime adapter (hooks).**
  `scripts/claude-code-trace-hook.sh`: guard chain (jq → JSON → trace-lib →
  issue context → event dispatch) with subshell containment so the hook can
  never disturb a session (exit 0 + empty stdout on every path, adversarial
  probes on record); PostToolUse tool spans (200-char args summary redacted
  before capping, Pre/Post duration correlation with delete-after-use state,
  outcome only on explicit is_error); Stop/SubagentStop agent spans plus an
  all-or-nothing model span from the transcript's last assistant entry
  (omit-never-fake). Template + guide under `docs/runtime-adapters/`
  (merge-never-overwrite install, privacy/attribution/overhead notes); zero
  coupling from core scripts, sensor-enforced. Four features, four sensors,
  adversarial + mutation evidence throughout.
- **#95 — Agent-span conventions + single-source handback helper.**
  `scripts/log-handback.sh`: conductor-invoked helper that validates closed
  role/step/outcome enums, emits the `agent` span, then appends the derived
  Action Log bullet — span and log line from one invocation, one redaction
  policy, span-drop warned explicitly, token fields omit-never-fake.
  Doctrine in harness.instructions.md §3 (conductor is the sole emitter;
  seven agent steps + six script steps partition the frozen 13-step enum);
  the four subagent files end handbacks with the verbatim payload line; a
  fixture-based meta sensor detects log-without-span / span-without-log
  drift (reference detector for #103). Four features, all mutation-proven.
- **#94 — Lifecycle and tool spans from all six harness scripts.**
  start-issue, check-feature-list, review-gate, create-pr, merge-pr, and
  finish-issue emit schema-v1 spans via stage-tracked EXIT traps (outcome,
  numeric exit_status/duration_ms, failure-stage attrs) with zero behavior
  change; refusal/usage paths emit nothing; the finish span survives worktree
  teardown because trace-lib now pins the trace file to the main-checkout
  root. The e2e sensor drives a full scripted lifecycle and pins the ordered
  span sequence (first trajectory fixture); the `trace_emission`
  harness-contract section freezes per-script span obligations. Seven new
  mutation-proven sensors.
- **#93 — `scripts/trace-lib.sh` span emitter with built-in redaction.**
  Sourceable `trace_span` library: schema-v1 JSONL to the per-issue
  `trace.jsonl` with auto-stamped `schema_version`/`timestamp`/
  `harness.issue`/`harness.version`/`span_id`, `TRACE_ISSUE` → branch →
  worktree issue resolution, `gen_ai.usage.*`-only numeric coercion,
  reserved-key protection, JSON-safe writer-level redaction (GitHub/AWS
  token shapes, Bearer/hyphenated headers, uppercase env-style
  assignments), and warn-only error paths that can never fail a caller.
  Contract v1 gained optional `span_id`/`parent_span_id` linkage fields.
  Registered in `harness-contract.yml`; guarded by three dedicated
  mutation-proven sensors plus contract backstops.
- **#92 — Trace schema v1 frozen as a machine-checkable contract.**
  `docs/evaluation/trace-schema.v1.json` (4 span types, 13-step lifecycle
  vocabulary, mandatory `schema_version` + `harness.version`, per-type OTel
  GenAI fields, trace-file contract at
  `.copilot-tracking/issues/issue-NN/trace.jsonl`, redaction-by-reference),
  guarded by `test_trace_schema.sh` (contract-driven jq accept/reject filter,
  earmarked for reuse by the #97 validator) and
  `test_trace_schema_docs.sh` (observability page defers to the contract; no
  competing vocabulary can drift).

### Lifecycle hardening — naming + verify gate
- **#129 — Enforce project-CI coverage for code surfaces (WARN in preflight,
  FAIL at Pre-PR gate).** `harness-smoke.yml` runs the harness's own sensors, not
  an adopting project's gates, so a project could accumulate unit tests that CI
  never ran. New `scripts/ci-coverage-lib.sh` detects a code surface
  (Python/Go/Node/Java/Ruby via `profile_detect`) that no `.github/workflows/*.y*ml`
  other than `harness-smoke.yml` covers, matching each profile's new
  `PROFILE_CI_SIGNATURES` gate-command tokens. `init.sh` preflight WARNs on the
  gap; a new fail-closed `review-gate.sh ci-gate` — embedded in the `check` case,
  so `create-pr.sh` enforces it with no edit — refuses to open the PR, with
  `SKIP_CI_GATE=1` as the logged escape hatch. The lib owns all language tokens so
  `review-gate.sh`/`create-pr.sh` stay `language_neutral` (contract test 11); the
  gate emits a `review-gate.ci-gate` trace span. Contract records `SKIP_CI_GATE`
  + the `ci-coverage-missing` failure mode. Four sensors
  (`test_init_ci_coverage_warn.sh`, `test_review_gate_ci_coverage.sh`,
  `test_ci_coverage_docs.sh`, plus the extended `test_harness_contract.sh`). No
  workflow template is shipped (projects author their own CI).
- **#84 — Unify repo-wide status doc as `docs/PROGRESS.md` + enforce it.**
  Renamed the status doc everywhere, declared it separate from the per-issue
  local `progress.md`, added a `review-gate.sh status-doc` gate (fails closed
  unless `docs/PROGRESS.md` changed in `main...HEAD`, no opt-out), and seeded
  this file.
- **#82 — Functionality product-quality rubric** for coding-agent work
  (`docs/evaluation/product-quality-rubric.md`), wired into tester and reviewer
  gates.
- **#80 — "What counts as one feature" granularity rule** + made the
  feature-breakdown evaluable.
- **#78 — Explicit plan → clarify → feature_list breakdown flow** (owner,
  ordering, human gate).
- **#76 — `install-harness.sh`** to copy the harness into a target project
  (ships skills, prompts, eval rubric docs; no skeletons).
- **#74 — `merge-pr.sh` rejects stray positional args** (e.g. a bare PR number)
  so it can't merge the wrong PR; it resolves the PR from the current worktree
  branch.
- **#53 — Public-repo exposure audit skill** (`public-exposure-audit`), wired
  into the review checklist and the closeout verify gate.
- **#51 — Harness smoke promoted to a strict CI merge/close gate**
  (`merge-pr.sh` refuses unless `gh pr checks` is green).
- **#46 — Tighter tester/reviewer blocking criteria.**
- **#49 — Standard-depth planner may use web research as a fallback.**

### Multi-language profiles
- **#35 — Declarative profiles + Python gate migration** (`profiles/`,
  profile contract in `profiles/README.md`).
- **#36 — Profile-aware agents.**
- **#37 — Language profile scaffold generator** (`scaffold-language.sh`).
- **#38/#39/#40/#41 — Node.js / Go / Ruby / Java profiles.**
- **#42 — Documented profile boundaries**
  (`docs/multi-language-profiles.md`, `test_docs_profile_boundaries.sh`).
- **#72 — Ruby profile fix:** Standard projects no longer mis-detected as
  RuboCop via a transitive lockfile dependency.
- **#44 — Bash script best-practice instructions**
  (`.copilot/instructions/bash.instructions.md`).

### Lifecycle contract & regression safety
- **#33 — Frozen harness lifecycle contract** (`docs/harness-contract.yml` +
  `test_harness_contract.sh`).
- **#34 — Strengthened script regression tests.**
- **#15 — Minimal feature-list completion check** (`check-feature-list.sh`).
- **#16 — Require a fresh review after the pre-PR rebase.**
- **#17 — Repaired `finish-issue` warning paths.**
- **#3 — HEAD-bound review gate before PR creation** (`review-gate.sh`).
- **#4 — Upgraded init gates + issue scaffold.**

### Copilot agent topology & process
- **#1 — Copilot implementation + test agents.**
- **#2 — Strengthened planning + review agents.**
- **#13 — Implementation-usefulness grading** in audit skills/subagents.
- **#14 — Grading-driven subagent revision loops.**
- **#22 — Subagents receive Python best-practice instructions.**
- **#25 — Conductor prevented from doing implementation/test work**
  (role separation).
- **#19 — Prompts require strict harness adherence.**
- **#18 — Removed project-specific devcontainer assumptions.**
- **#21 — Removed markdownlint from the required harness flow.**

### Foundations
- **#6 — Documented the Copilot harness lifecycle** (`docs/HARNESS.md`).
- **#5 — Harness smoke CI** (`.github/workflows/harness-smoke.yml`) without
  restoring CI/CD delivery.

---

## Conventions for continuing this log

- **Newest first** under *Delivered*; group by workstream, reference the issue
  number and the concrete artifact(s) it added.
- Keep *Snapshot* and *Next up* current — a fresh agent should be able to read
  only those two sections and know where to start.
- This file tracks **repo-wide** status only. Per-issue blow-by-blow stays in
  the local, gitignored `.copilot-tracking/issues/issue-NN/progress.md`.
