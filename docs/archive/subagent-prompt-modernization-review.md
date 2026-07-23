# Subagent Prompt Modernization Review — `.copilot/agents/`

**Date:** 2026-07-08
**Reviewed against:** current frontier coding models (Claude Opus 4.8-class / GPT-5.5-class)
**Companion to:** `docs/skill-prompt-modernization-review.md` (skills review; epic #176)

Same question as the skills review: *which instructions still steer, and which compensate for
model weaknesses that no longer exist?* The answer here is different, and that difference is the
headline.

---

## Summary

| Agent | Lines | Verdict | Proposed action | Est. after |
| --- | --- | --- | --- | --- |
| `implementation-subagent` | 77 | Well-calibrated | Fix routing gaps, dedupe shared blocks | ~60 |
| `test-subagent` | 132 | Sound policy, repeats itself | Single-source rubric, collapse repetition | ~85 |
| `planning-subagent` | 265 | Good bones, double-encoded | Merge duplicate depth/web-rule encodings | ~150 |
| `code-review-subagent` | 408 | Sound but bloated + stale pin | Single-source rubric, cut examples, fix model pin | ~230 |

Total ~882 → ~525 lines projected.

**Key difference from the skills review:** the skills contained obsolete *content* (tool
tutorials, fabricated examples, anti-derailment scaffolding). The subagents contain almost none
of that — they are predominantly **harness policy**: role boundaries, sensor discipline,
handback contracts, lifecycle gates. That content does not age with model capability and must
stay. The problems here are structural instead:

1. **Duplication across files** — the same blocks pasted into 3–4 agents (drift risk).
2. **Duplication within files** — the same rule restated 3–4 times per file
   (Opus 4.5-era emphasis-by-repetition; a modern model follows a rule stated once, firmly).
3. **Restating canonical docs** — the product-quality rubric re-encoded in two agents instead of
   referenced (the exact drift pattern issue #173 fixes for the trace schema).
4. **A few real bugs** — an incomplete routing map, a stale model pin, and a dependency on the
   `general` skill that #177 is about to delete.

---

## Cross-cutting findings

### A-X1: Profile-aware routing map is duplicated 4× — and it is wrong (bug)

Every agent carries a near-verbatim copy (~12–15 lines each) of the extension→language routing
map: `.py` → `python`, `.go` → `go`, `.ts`/`.tsx`/`.js`/`.jsx` → `node`, `.java` → `java`,
`.rb` → `ruby`.

Two problems beyond the duplication:

1. **The map routes to five instruction files, of which four don't exist.** Only
   `python.instructions.md` is provisioned. There is a fallback clause, so this is not a hard
   failure — but the map is mostly aspirational.
2. **The map omits two instruction files that DO exist**: `bash.instructions.md` and
   `terraform-azure.instructions.md`. A subagent editing `.sh` or `.tf`/`.bicep` files follows
   the fallback path and never loads the bash/terraform instructions that were written precisely
   for it. This silently defeats the purpose of profile-aware routing for the two extra
   languages this repo actually has.

**Action:** single-source the routing map (natural home:
`.copilot/instructions/harness.instructions.md`, which all agents already treat as contract),
make it match reality (add `.sh` → `bash`, `.tf`/`.bicep` → `terraform-azure`; keep unprovisioned
languages as one fallback sentence), and replace the four copies with a one-line reference.
Consider a drift sensor per the #173 pattern: a check that every `*.instructions.md` on disk is
reachable from the routing map.

### A-X2: All four agents depend on the `general` skill that #177 deletes (coordination bug)

Each agent's fallback clause points at `.copilot/skills/general/SKILL.md`. Issue #177 deletes
that skill. If #177 lands as scoped, all four agents get a dead reference — the exact defect
class #177 exists to fix.

**Action:** fold into #177 (its scope is "remove dead references") or sequence explicitly:
re-point the fallback to the harness contract
(`harness.instructions.md` + `tdd.instructions.md`), which the clause already names anyway —
the `general` half of the fallback adds nothing the contract doesn't cover.

### A-X3: Product-quality rubric is re-encoded, not referenced (drift risk)

`docs/evaluation/product-quality-rubric.md` is the declared source of truth. Yet:

- `test-subagent` restates the four blocking gates in full.
- `code-review-subagent` restates the four gates **twice** (Verdict 2 checklist + "Four Blocking
  Gates" subsection) *and* the full six-dimension scorecard with its 0–12 scoring bands.

Three re-encodings of one rubric = three places to drift when the rubric changes. This is the
same single-source problem the repo already solved for the trace schema (#173).

**Action:** each agent keeps (a) a one-line pointer to the rubric doc, (b) the gate *names* only,
and (c) the agent-specific part — evidence requirements and routing rules (which role fixes which
gap). Delete the duplicated gate definitions and scorecard bands; the fresh-context agent reads
the rubric doc, which it must already do (`docs/evaluation/product-quality-rubric.md` is named as
the authority in both files).

### A-X4: Emphasis-by-repetition within files

Opus 4.5-era prompts repeated critical rules because older models dropped instructions under
context pressure. Current models don't need this, and the repetition dilutes the rest:

- `test-subagent`: "never mark `passes:true` without gate evidence / never weaken a sensor"
  appears ~4 times (Blocking Criteria, Product-Quality Gates, Workflow step 4–5, Output Format,
  Handback classification).
- `planning-subagent`: the write-scope restriction (`only .copilot-tracking/plans/`) appears 3
  times (intro, Step 4, Rules); the web-research fallback rules appear twice nearly verbatim
  (`standard` and `deep` sections); the per-depth research behavior is encoded twice (Planning
  Depth section + Workflow Step 1 per-depth lists).
- `code-review-subagent`: "blocking findings first" appears 5+ times; "you do not call other
  subagents directly — the conductor owns the loop" appears in multiple agents multiple times.

**Action:** state each rule once in its strongest position (usually the section where it gates an
action), keep at most one reinforcement in the output-format template. In `planning-subagent`,
merge the two depth encodings into one table; hoist the web-research rules into a single
subsection referenced by both depths.

### A-X5: Handback payload-line instructions duplicated 4×

The `scripts/log-handback.sh` payload spec (`[<role>] <step> <feature_id> <outcome> — <summary>`
plus the "never invent token counts" caveat) is pasted into all four agents with only the
role/step names varying.

**Action:** move the format spec next to the routing map in the shared contract (A-X1's home);
each agent keeps one line: its role name and valid step values. Note: the "never estimate token
counts" caveat is a *real, still-current* failure mode (models fabricating telemetry) — keep it,
but once, in the shared spec.

### A-X6: Stale model pin in `code-review-subagent` (bug)

Frontmatter: `model: Claude Opus 4.7 (copilot)`. Current Copilot model lineup has moved past
this (Opus 4.8 / GPT-5.5 / Claude 5 era). Depending on how Copilot resolves unknown pins, this
either silently falls back or fails.

**Action:** decide policy — pin to the current strongest available review model, or remove the
pin and inherit the session model. Whichever is chosen, add the pin to the sync-docs/exposure
review surface so the next model generation doesn't strand it again.

---

## Per-agent findings

### A-1: `implementation-subagent` (77 → ~60 lines)

The best-calibrated of the four: tight role boundaries, minimal ceremony, no worked examples, no
tutorials. Changes are all inherited from cross-cutting items:

1. A-X1 (routing map → shared, fixed), A-X2 (general-skill fallback), A-X5 (handback spec).
2. Keep verbatim: the scope rules (no tests, no `passes:true`, no commits, no scope-broadening),
   the handback-decision routing (`*-now` vs `Plan first` vs `Defer`), and the blocking-question
   escape hatch. All policy.

### A-2: `test-subagent` (132 → ~85 lines)

The sensor-discipline policy (criterion→sensor mapping, happy-path-only = BLOCKING,
conductor-only waivers) is the harness's core IP — keep all of it, stated once.

1. A-X3: replace the four-gates restatement with gate names + pointer to the rubric doc +
   the evidence requirement.
2. A-X4: collapse the ~4 restatements of "no pass without evidence / never weaken a sensor" into
   one authoritative statement in Blocking Criteria plus the Output Format field.
3. A-X1/X2/X5 as above.
4. Keep: the handback classification taxonomy (production defect vs sensor gap vs failed gate,
   with routing) — that's the Loop-1 contract and it's stated only once.

### A-3: `planning-subagent` (265 → ~150 lines)

Good bones — the depth system (quick/standard/deep), artifact-nameable stop criteria ("the test
is whether you can name the source, not whether you feel confident"), and the mandatory Open
Questions section are genuinely modern prompt design. The problem is double encoding:

1. **Merge the two depth encodings** — "Planning Depth" section and "Workflow Step 1" repeat the
   same per-depth behavior; keep one table (depth × research/web/output/phases/stop), delete the
   prose duplicate. Biggest single win (~50 lines).
2. **Hoist web-research rules** — the `standard` and `deep` paragraphs are ~90% identical; one
   subsection, referenced twice.
3. A-X4: write-scope rule stated once (in Rules, the strongest position) instead of 3×.
4. A-X1/X2/X5 as above.
5. Keep: the plan format template (output consistency), the stop-when criteria per step, the
   "two consecutive searches return only known files → stop" heuristic (cheap, still useful),
   and the feature_list ownership boundary (conductor authors it, planner surfaces blockers).
6. Delete: "Work autonomously without pausing for feedback" — subagent runtime property, not an
   instruction the model can act on.

### A-4: `code-review-subagent` (408 → ~230 lines)

The most valuable and the most bloated. The four-verdict structure, the finding-pass vs
reporting-pass split, and the severity/confidence ladders are all worth keeping — with one
notable observation: the two-pass split ("surface everything internally, filter at reporting")
targets a failure mode (silent recall loss under severity filters) that is **still real** in
current models. Keep it — this is the rare anti-derailment scaffolding that has not expired.

1. A-X3 (biggest win, ~60 lines): delete the duplicated four-gates subsection and the
   six-dimension scorecard bands; keep verdict names, evidence requirements, and routing.
2. **Cut both worked examples (~50 lines)** — same rationale as the skills review S-4: the two
   output templates fully specify the format; APPROVED/NEEDS_REVISION examples teach a frontier
   model nothing. (The templates themselves stay — output-shape consistency is policy.)
3. **Fix the model pin** (A-X6).
4. **Consider dropping to one output template** — concise and full differ only in which sections
   are included; a modern model can derive concise from full plus the mode description. Keeping
   both is defensible; keeping both *plus* examples is not.
5. Skill-integration points (checks 6–11 referencing `find-brute-force` etc.) are good
   indirection — they reference rather than restate. Verify the pointers survive the
   skill-modernize rewrites (#178–#180), especially if `security-audit` is deleted.
6. Keep: the acceptance-criteria-vs-plan-wording tolerance rules (blocks real false positives),
   the usefulness-decision → severity mapping (policy), "What You Do NOT Check".

---

## Suggested issue breakdown

Sized per the 2–5-features convention; note the ordering dependency with the skill-modernize
epic #176:

1. **Issue: fix subagent routing + stale references (bugs)** — A-X1 routing map corrections
   (add `bash`, `terraform-azure`; single-source), A-X2 general-skill fallback re-pointing
   (**must land with or before #177**), A-X6 model pin. Small, highest urgency.
2. **Issue: single-source the product-quality rubric in subagents** — A-X3 for `test-subagent` +
   `code-review-subagent`, plus a drift sensor per the #173 pattern.
3. **Issue: collapse intra-file repetition + shared handback spec** — A-X4 across all four
   agents, A-X5 shared payload spec, planning-subagent depth-table merge, code-review worked
   examples cut.

**Validation:** same bar as #176 — pre/post run of one conductor loop (plan → implement → test →
review) on a small issue; role boundaries, gate evidence, and handback payloads must be
unchanged or better with the smaller prompts.
