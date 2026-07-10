# `.copilot/` Full Health Check

> **⚠️ Superseded — historical snapshot.** This report is a point-in-time
> record of `.copilot/` health as of **2026-07-08**. The findings below were
> triaged and remediated through issues **#178, #179, #180, #181, #184** and
> later hardening; it is retained for provenance and is **not** the live state
> of the harness. For current status see [docs/PROGRESS.md](PROGRESS.md) and
> [docs/HARNESS.md](HARNESS.md). The original verdict and findings are kept
> verbatim below.

**Date:** 2026-07-08
**Scope:** all 20 files / 3,499 lines under `.copilot/` — `agents/` (4), `instructions/` (6),
`prompts/` (1), `skills/` (9)
**Builds on:** `docs/skill-prompt-modernization-review.md` (skills) and
`docs/subagent-prompt-modernization-review.md` (agents); this report rolls up their status
post-#177/#182/#183 and adds the first review of `instructions/` and `prompts/`.

---

## Overall verdict

| Area | Files | Lines | Health | Open work |
| --- | --- | --- | --- | --- |
| `skills/` | 9 | 1,655 | ⚠️ Reviewed; fixes in flight | #178, #179, #180, #181 |
| `agents/` | 4 | 845 | ⚠️ Bugs fixed; slimming unfiled | #184 open; rubric single-source + repetition unfiled |
| `instructions/` | 6 | 977 | 🟡 Mostly sound; 4 new findings | Not yet filed (this report) |
| `prompts/` | 1 | 22 | ✅ Healthy | None |

Workstream status (epic #176): #177 (delete `general`, create-pr refs), #182 (routing map), and
#183 (general-skill fallback) have **merged**. #184 (stale model pin) is open and the pin is
still present (`code-review-subagent.agent.md:5`). #178/#179/#180/#181 are open and unstarted.

The new findings below are concentrated in `instructions/`, and they are a *different genre*
from the skills problems: not obsolete-for-modern-models content, but **provenance
contamination** (product-specific references from the project this harness was extracted from)
and **stale alternate-generation content** (a workflow shape this repo no longer has).

---

## New findings — `instructions/` and `prompts/`

### C-1: Foundry/CU product leakage across four instruction files (provenance contamination)

This is a *public, reusable* harness, but four instruction files still carry references to the
specific Azure AI Foundry / Content Understanding product the harness was extracted from:

- `harness.instructions.md` §7: "Parse/validate structured outputs **from Foundry**…", "Foundry
  endpoints + keys live in `.env` / Key Vault; never embed a `<resource>.openai.azure.com` URL",
  §2 "For **Foundry** / Terraform / deploy work, run `REQUIRE_AZ=1`", §4 "(**Foundry call** on a
  fixed fixture…)".
- `tdd.instructions.md`: "Mock at the **Foundry boundary** (the model client, the **CU client**,
  the Code Interpreter session)".
- `python.instructions.md`: "**Foundry endpoint, key, deployment names, blob container, and
  resource group** all come from env".
- `terraform-azure.instructions.md`: "Azure AI **Foundry** projects", "**Content Understanding**
  resources", "For a **1-week POC**, a single `dev` env is usually enough".

For an adopting project that doesn't use Foundry, these instructions are noise at best and
misleading at worst (a subagent may look for a "Foundry boundary" that doesn't exist). The
*principles* are right — typed parsing at external boundaries, secrets from env, mock at the
service client; only the product nouns need genericizing ("the external service boundary", "the
model/service client"). Where a concrete example helps, mark it as an example
("e.g., an Azure AI Foundry endpoint") rather than a fact about the repo. `REQUIRE_AZ` is real
harness surface (`init.sh`) and stays; the doctrine prose around it shouldn't presume Azure.

Est. ~15 lines changed across 4 files. Also a candidate check for `sync-docs`/exposure hygiene:
product nouns in generic harness files.

### C-2: Verify-gate sensor list depends on the #178 decision (coordination)

`harness.instructions.md:373` names `security-audit` in the **authoritative** Pre-PR verify-gate
inferential sensor list (§6, "everywhere else that mentions 'the verify-gate sensors' means
exactly these"). Issue #178's recommended option (a) deletes that skill. If (a) is chosen, this
list must be updated in the same PR, or every future PR's verify gate names a missing sensor —
the same dead-reference class #177 just fixed. Add this to #178's task list.

### C-3: `workflow-tiers.instructions.md` "Optional: Issue-driven harness" section is stale

The section (lines ~165–179) describes a **Taskfile-based** harness: `task preflight`,
`task init-issue ISSUE=<N>`, `task finish-issue ISSUE=<N>`, and
`.github/templates/feature_list.json`. Verified: this repo has **no Taskfile** and its lifecycle
is script-based (`scripts/start-issue.sh`, `scripts/finish-issue.sh`, per-issue scaffolding under
`.copilot-tracking/issues/`). The section appears to describe an earlier generation of the
harness (or a different host repo) that no longer matches anything here.

Since this file is the *cross-project personal* doctrine, a task-based host repo could
theoretically exist — but describing one concrete stale shape invites the conductor to hunt for
`task init-issue` where it doesn't exist. Fix: either delete the section (the file already says
"use the host repo's skill/harness if present") or rewrite it to one generic sentence ("when the
host repo provides its own issue-lifecycle commands, prefer them over this file's defaults").

### C-4: Emphasis-by-repetition in the two doctrine files (same A-X4 pattern as agents)

- `harness.instructions.md` §3 "non-delegable" block states the same prohibition ~4 times in
  ~17 lines ("must not directly perform", "In plain terms:", "Specifically, the conductor must
  not:", "The conductor does not implement and the conductor never writes…"). One firm statement
  plus the bullet list suffices (~8 lines saved). The rule itself is core policy — keep it
  BLOCKING-strength, state it once.
- `workflow-tiers.instructions.md` repeats its stop rules across three sections (Mid-pipeline
  rules / When to Stop and Ask / Important Rules): "never retry more than twice" ×2, "include the
  full feedback — don't summarise or soften" ×2 verbatim, subagent-blocker handling ×3. Merge
  into the "When to Stop and Ask" section (~25 lines saved).
- Minor structural nit in `harness.instructions.md`: the "Red → Green → Refactor" bullet
  (~line 260) visually dangles after the long instruction-passing subsection — it belongs with
  the §3 opening bullets. Pure readability, fix opportunistically.

These two files are otherwise **sound**: the lifecycle, role separation, sensor doctrine,
severity→action table, and agent-span conventions are exactly the durable policy a doctrine file
should hold, and the tier system in workflow-tiers is well-calibrated for current models.

### Per-file notes — the healthy ones

- **`bash.instructions.md` (83) — exemplary.** Deeply project-specific (worktree path
  canonicalization, fake-CLI isolation, mutation-testing guards, `write-tree`/`commit-tree`
  pattern, hard-fail vs warn semantics tied to `harness-contract.yml`). Zero training-data
  restatement. This is the reference standard the other instruction files should be held to.
- **`tdd.instructions.md` (53) — keep.** The snapshot-test-for-prompt-assets equivalence is
  genuine project policy. Only change: the Foundry/CU line (C-1).
- **`python.instructions.md` (61) — keep.** Test-layout mirroring rules and uv discipline are
  project policy. Only change: the Foundry env line (C-1).
- **`terraform-azure.instructions.md` (87) — borderline, low priority.** Roughly half is generic
  Terraform practice a modern model knows (version pinning, remote state, fmt/validate/plan
  ceremony); the other half is real policy (azapi for uncovered resources, `prevent_destroy` on
  data stores, the data-agreement destroy rule). Could trim ~30 lines, but it's inert until a
  `.tf` surface exists — do it opportunistically with C-1, not as its own issue.
- **`prompts/session-ritual.prompt.md` (22) — healthy.** Current paths, correct role-separation
  summary, right delegation to the doctrine files. No changes.
- **`harness.instructions.md` (476) overall** — the longest file in `.copilot/` and it earns it.
  Apart from C-1/C-2/C-4 above, no modernization cuts recommended: this is the policy core the
  skills/agents reviews explicitly protect.

---

## Rolled-up status of previously reviewed areas

### `skills/` (post-#177)

`general` deleted; `create-pr` re-pointed and slimmed (88→49 lines). Remaining, all filed:

- #178 — replace/delete imported `security-audit` (134) + cut `code-review` worked examples
  (180→~55). **Now also carries C-2** (update the harness §6 sensor list if deleting).
- #179 — dedupe the 4 audit skills' shared boilerplate (grading rubric, exclusions, plan
  templates; ~200+ lines).
- #180 — strip anti-derailment scaffolding + regex seeds (`dead-code-detection` step 4,
  `sync-docs` warnings, `find-*` seeds).
- #181 — backlog: repo-specific PR conventions.

### `agents/` (post-#182/#183)

Routing map single-sourced into `harness.instructions.md` with a drift sensor (#182);
`general` fallbacks re-pointed (#183). Remaining:

- **#184 (open bug)** — `model: Claude Opus 4.7 (copilot)` pin still present at
  `code-review-subagent.agent.md:5`.
- **Unfiled** (from the subagent report): product-quality rubric re-encoded in `test-subagent` +
  `code-review-subagent` instead of referenced (A-X3, ~60 lines, #173-style drift risk);
  intra-file repetition + shared handback spec + planning-subagent double encoding + worked
  examples cut (A-X4/A-X5, ~250 lines).

---

## Suggested issue breakdown (new work from this report)

1. **Issue: genericize product-specific references in instruction files** — C-1 across
   `harness`/`tdd`/`python`/`terraform-azure` + the terraform generic-half trim. Small,
   self-contained.
2. **Issue: prune stale/duplicated doctrine content** — C-3 (workflow-tiers Taskfile section) +
   C-4 (repetition in both doctrine files). Small.
3. **File the two outstanding subagent cleanups** from the subagent report (rubric
   single-source; repetition/handback-spec/examples) — already specced there as issues 2–3.
4. **Amend #178** with C-2 (harness §6 sensor-list update on delete).

With these filed, every file under `.copilot/` is either verified healthy or covered by an open
issue — that is the definition of "health check complete" for this report.

## Updated execution order

Decide #178a/b → #184 (trivial) → #178 (with C-2) → #179 → #180 → new-1 (C-1) → new-2 (C-3/C-4)
→ subagent cleanups → #181. The C-1/C-3/C-4 items touch different files from #179/#180, so they
can run in parallel with the skill work if capacity allows.
