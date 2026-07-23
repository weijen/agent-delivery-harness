# Skill Prompt Modernization Review — `.copilot/skills/`

**Date:** 2026-07-08
**Reviewed against:** current frontier coding models (Claude Opus 4.8-class / GPT-5.5-class)
**Context:** These skills were authored in the Opus 4.5 era. This review asks one question per
skill: *which instructions are still doing work, and which are compensating for model weaknesses
that no longer exist?*

Each finding below is written to be liftable into a standalone GitHub issue. Cross-cutting
findings (X-1 … X-5) should generally be filed before per-skill issues, since several per-skill
fixes fall out of them.

---

## Summary

| Skill | Lines | Verdict | Proposed action | Est. size after |
| --- | --- | --- | --- | --- |
| `general` | 23 | Obsolete | Delete (or absorb into AGENTS.md) | 0 |
| `create-pr` | 88 | Over-specified + dead references | Rewrite slim | ~35 |
| `security-audit` | 134 | Imported generic, misfit | Replace or delete | ~40 or 0 |
| `code-review` | 183 | Worked examples obsolete | Cut examples, keep rubric | ~55 |
| `dead-code-detection` | 161 | Mostly sound | Remove anti-derailment scaffolding | ~120 |
| `public-exposure-audit` | 186 | Best-calibrated | Minor trims only | ~165 |
| `sync-docs` | 190 | Sound core, verbose edges | Trim ~25% | ~140 |
| `find-brute-force` | 227 | Sound core, shared boilerplate | Dedupe + trim | ~130 |
| `find-duplicates` | 249 | Sound core, shared boilerplate | Dedupe + trim | ~140 |
| `find-over-design` | 279 | Ironically over-designed | Dedupe + trim | ~150 |

Total: ~1,720 lines today → ~975 lines projected. The goal is not line count for its own sake:
every line in a skill body is context spent on *every* invocation, and instructions that restate
model-native behavior dilute the instructions that actually steer.

### What modern models no longer need (the recurring pattern)

1. **Tool-use tutorials** — `git checkout -b`, `gh pr create` invocations, generic `rg` recipes.
   Frontier models know these commands; showing them only anchors the model to one specific shape.
2. **Long worked examples** — full sample findings with fabricated CWE tables and before/after
   code. Modern models generalize from a one-line format spec; 70-line examples cost context and
   risk example content leaking into real reports (anchoring).
3. **Anti-derailment scaffolding** — "if a command fails, don't keep retrying the same shape",
   "don't flag regex examples as stale prose", "treat invalid `/src/...` paths as a
   path-resolution problem". These were written to patch specific Opus 4.5-era failure loops.
   Current models recover from these natively; the instructions now read as noise.
4. **Meta-narration** — "This skill enables the agent to…" preambles that describe the skill to a
   human rather than instructing the model.
5. **Baked-in best practices** — "keep PRs small", "write meaningful variable names", "MD5 is
   broken". This is training-data knowledge; restating it adds nothing.

### What is still earning its place (do not cut)

- **Judgment codification**: classification tables (Exposure vs Accept), severity ladders,
  "Legitimate Duplication To Accept" lists. These encode *project policy*, not model capability —
  a stronger model doesn't know your risk tolerance.
- **Report templates**: output-format consistency across runs is a harness property, not a model
  property. Keep them (but one template per skill, not two).
- **Scope/exclusion decisions**: which docs are Tier 2 historical, what counts as oxbow code,
  when history sweeps are required. Domain policy — keep.
- **Completion criteria**: cheap (3–5 lines) and effective at preventing premature stop. Keep.

---

## Cross-cutting findings

### X-1: Deduplicate shared boilerplate across the four audit skills

**Skills affected:** `find-brute-force`, `find-duplicates`, `find-over-design`,
`dead-code-detection` (and lightly `public-exposure-audit`).

Four blocks are repeated near-verbatim in each skill:

1. The **exclusion list** (`.venv/`, `node_modules/`, `dist/`, `build/`, `target/`,
   `.terraform/`, `.next/`, `.nuxt/`, `coverage/`, `.git/` …) — 4 copies.
2. The **"Search broadly, judge narrowly"** core-principle paragraph — 4 copies with cosmetic
   variation.
3. The **Implementation-Usefulness Grading** rubric (5 dimensions × H/M/L → Fix now / Plan first /
   Defer-accept, plus the "decision does not override severity" caveat) — 4 copies,
   ~25 lines each (~100 lines total).
4. The **report structure** (Findings table → Details → Accepted Patterns → Optional plan) —
   4 copies.

This is exactly the duplication `find-duplicates` would flag in code. Options, in order of
preference:

- **(a) Extract** a shared `_audit-conventions.md` in `.copilot/skills/` that each skill
  references in one line ("Apply the shared audit conventions: exclusions, grading, report
  shape"), keeping only skill-specific deltas inline. *Caveat: verify the Copilot skill loader
  resolves relative file references from a skill body before choosing this.*
- **(b) Slim in place**: reduce the grading rubric to 3 lines per skill ("After classifying,
  grade each finding Fix now / Plan first / Defer-accept based on evidence strength, payoff, and
  blast radius; the decision never overrides severity") and keep one canonical exclusion list per
  skill as a single line.

Even option (b) alone saves ~200 lines across the four skills with no behavioral loss — a modern
model does not need five named dimensions with H/M/L scoring to make a fix-now-vs-defer call; it
needs the decision vocabulary and the safety caveat.

### X-2: Remove anti-derailment scaffolding written for older models

**Skills affected:** `dead-code-detection` (step 4, ~15 lines), `sync-docs` (step 6 warnings),
`find-brute-force` (scattered).

Concrete examples:

- `dead-code-detection` step 4 ("Keep tool execution simple and recoverable") is an entire
  section teaching the model not to loop on failed commands, how to recognize subagent path
  hallucination (`/src/...`), and that a shell YAML parser is "optional, not the only source of
  truth". This reads as a postmortem of one specific bad session, generalized into permanent
  instructions. Current models do not exhibit these loops; delete the section or compress to one
  sentence ("Record which commands ran and which could not, so the report is reproducible" — the
  only durable requirement in it).
- `sync-docs` step 6: "Do not flag examples inside fenced code blocks as unfinished instructions,
  and do not treat regex examples as stale prose" — old-model false-positive patch. One could
  argue it's cheap insurance; recommend deleting and re-adding only if the failure reappears in
  eval traces.

**Principle to adopt:** anti-derailment instructions should be treated like feature flags for a
disease that got cured — remove them, and let the eval suite (not fear) decide if any come back.

### X-3: Remove tool-use tutorials and generic command recipes

**Skills affected:** `create-pr` (Commands section), `sync-docs` (Useful Inventory Commands),
`public-exposure-audit` (partially — see per-skill note), `find-brute-force` /
`find-duplicates` / `find-over-design` (Common Search Seeds).

Distinguish two cases:

- **Generic recipes** (`git checkout -b`, `rg --files -g '!node_modules'`): pure tutorial, delete.
- **Coverage checklists disguised as regexes** (find-brute-force's Common Search Seeds): the
  *category list* (marker comments, swallowed errors, timing hacks, security shortcuts, debug
  leftovers) is valuable as a completeness checklist; the literal regex alternations are not —
  the model writes better, language-adapted patterns itself. Keep the categories as prose bullets,
  drop the regex strings. Roughly halves those sections.
- **Non-obvious invocations** (`git grep <pattern> $(git rev-list --all)` in
  public-exposure-audit): keep — sweeping all reachable history is genuinely non-default behavior
  and the command encodes the policy.

### X-4: Remove Remediation Plan Templates

**Skills affected:** `find-brute-force`, `find-duplicates`, `find-over-design` (~45 lines each,
~135 total).

Each ends with a second full markdown template for a remediation plan that is only used "when the
user asks". Modern models produce well-structured plans unprompted; the only durable requirements
are already stated elsewhere ("use repository-local planning conventions when present; include
test impact and verification"). Replace each template with that one sentence.

### X-5: Frontmatter and naming consistency

- `code-review/SKILL.md` uses `name: Code Review` (spaces, title case); every other skill uses
  kebab-case matching its folder. Normalize to `code-review`.
- `security-audit` and `code-review` carry `license`/`metadata.author: awesome-ai-agent-skills`
  frontmatter revealing they were imported wholesale from a public collection rather than written
  for this repo (see S-3, S-4).
- Only the newer skills (`dead-code-detection`, `public-exposure-audit`, `sync-docs`,
  `find-*`) have `argument-hint`. Add it to the survivors of the rewrite or drop it uniformly.

---

## Per-skill findings

### S-1: `general` — delete

**Verdict: obsolete.** All 18 content lines ("meaningful variable names", "keep commits atomic",
"write tests for new functionality") are training-data platitudes that add zero steering on a
2026 model — they were marginal even on Opus 4.5. Worse, as an always-plausible-to-trigger skill
it can consume a trigger slot without changing behavior.

**Action:** delete the skill. If any line is genuinely a *project* convention (rather than a
universal one), move it to `AGENTS.md` where repo-wide conventions already live.

### S-2: `create-pr` — rewrite slim (~88 → ~35 lines)

Problems:

1. **Dead references (bug, not just bloat):** step 3 mandates quality gates via
   `skills/typescript`, `skills/python`, `skills/testing` — none of these exist in
   `.copilot/skills/`. A model following instructions literally will search for missing skills or
   silently skip a mandated gate. Fix regardless of any trimming.
2. **Git tutorial:** the Commands section teaches `git checkout -b` / `git add -A` /
   `gh pr create`. Delete. (`git add -A` is also questionable advice — it stages everything,
   which conflicts with this repo's public-exposure hygiene.)
3. **Baked-in best practices:** "keep PRs under 400 lines", "use draft PRs", "request specific
   reviewers" — training-data knowledge, delete.

Keep: branch naming convention, Conventional Commits type list, the PR description template
(project policy on PR shape), the quality-gate *concept* re-pointed at skills that exist
(`code-review`, `security-audit` or its successor), and the fork/multi-remote edge cases
(genuinely non-obvious `gh` flags).

**Also decide:** whether the repo's actual PR conventions (e.g. the `feat(#151): …` issue-number
style visible in git history) should be codified here — right now the skill describes generic
conventions, not this repo's.

### S-3: `security-audit` — replace or delete (~134 → ~40 or 0 lines)

This is an imported generic skill (`author: awesome-ai-agent-skills`) that doesn't match this
repository:

1. **~70 lines are worked examples** — fabricated findings tables (Express.js SQL injection, AWS
   Prowler output) with fake account IDs and CWE mappings. Modern models know OWASP/CWE cold;
   the examples teach nothing and risk anchoring real reports to the fabricated ones.
2. **Mandates tools that aren't here:** OWASP ZAP, Prowler, ScoutSuite, Trivy — none installed or
   referenced anywhere in this repo. Contrast with `public-exposure-audit`, which explicitly
   works with built-in git/grep and treats scanners as optional; that is the right calibration.
3. **Scope mismatch:** the skill assumes a deployed three-tier web app with cloud infra; this
   repo is a harness/docs/scripts project. Its real security surface (secrets in a public repo,
   script injection, workflow permissions) is better covered by `public-exposure-audit` and
   `find-brute-force` step 7.

**Action (pick one):**
- **(a) Delete** and let `public-exposure-audit` + `find-brute-force` own the security surface, or
- **(b) Rewrite** as a ~40-line repo-scoped skill: shell/CI script injection, workflow
  permissions, dependency pinning, secrets handling — with the same "built-in tools first,
  scanners optional" stance as `public-exposure-audit`, and severity/classification tables as the
  only retained structure.

### S-4: `code-review` — cut worked examples (~183 → ~55 lines)

Same import lineage as S-3. The two worked examples (Python auth function, orders.js PR diff)
total ~110 lines and demonstrate findings — SQL injection, MD5 password hashing, timing attacks,
N+1 queries — that any frontier model identifies without prompting. Delete both.

Keep (it's good): the 6-step workflow (especially step 2, "understand intent before judging" —
that's review *policy*), the checklist table, severity vocabulary (Critical/Warning/Info), the
Best Practices that encode reviewer etiquette rather than knowledge ("limit to top 5–7 findings",
"review the diff, not the file", "acknowledge good patterns"), and the Edge Cases list in
compressed form.

Also fix frontmatter name (X-5) and drop the "This skill enables an AI agent to…" preamble.

### S-5: `dead-code-detection` — remove scaffolding, keep the discipline (~161 → ~120 lines)

The strongest of the older skills: oxbow-code vocabulary, the static/semantic/dynamic evidence
split, and the classification ladder are genuine domain policy. Changes:

1. **Delete step 4** ("Keep tool execution simple and recoverable") — pure anti-derailment
   scaffolding (see X-2). Retain only "capture exact commands that worked and that could not run".
2. **Slim the Implementation-Usefulness Grading** per X-1 — but keep the *Defer-protect default*
   for public APIs/extension points verbatim; that's a real safety policy.
3. Merge "When to Use" into the frontmatter description (it already largely duplicates it).
4. Keep: Core Principle, procedure steps 1–3 and 5–10, Evidence Checklist, Common Patterns list
   (compressed), Completion Criteria. Tool Notes can compress to 2–3 lines.

### S-6: `public-exposure-audit` — minor trims only (~186 → ~165 lines)

The best-calibrated skill in the directory and the closest to this repo's actual needs. It
already embodies the right modern posture: built-in tools first, classification over pattern
matching, explicit Accept criteria, residual-risk honesty about published history.

Minor changes only:

1. Compress "When to Use" (duplicates the description).
2. Keep the git command block — `git grep $(git rev-list --all)` and the metadata sweep encode
   non-default policy, not tutorial content (X-3 exception).
3. Align its lightweight grading section's vocabulary with whatever X-1 lands on
   (Fix now / Plan first / Defer-accept).

### S-7: `sync-docs` — trim edges, keep the tier system (~190 → ~140 lines)

The Tier 1/2/3 doc-treatment system and the high-rot claim table are the core value — keep both
fully. Trims:

1. Delete the "Useful Inventory Commands" block (generic `rg` recipes — X-3).
2. Compress the exhaustive enumerations: step 3's inventory lists and the folder-name inference
   list (`archive/`, `archived/`, `historical/`…) can each drop to one representative line; the
   model extrapolates.
3. Remove step 6's fenced-code-block/regex false-positive warnings (X-2).
4. Keep: Core Principle, tier table, live-probe safety rules (read-only, never override desired
   state — genuine policy), editing rules, fix table, report template, completion criteria.

### S-8: `find-brute-force` — dedupe and trim (~227 → ~130 lines)

Core judgment framework (severity criteria, fix-strategy table, "search broadly, judge narrowly")
is sound. Changes:

1. Apply X-1 (grading rubric → 3 lines), X-3 (Common Search Seeds: keep the category checklist,
   drop the literal regexes), X-4 (delete Remediation Plan Template).
2. Compress procedure steps 3–8: each currently enumerates 10–20 example patterns; 4–6
   representative ones suffice — the categories are the instruction, the enumerations were
   old-model recall aids.
3. Keep: step 11 ("search for existing helpers before proposing code changes" — real policy),
   the Accept row semantics, and the report template.

### S-9: `find-duplicates` — dedupe and trim (~249 → ~140 lines)

Same treatment as S-8 (X-1, X-3, X-4). Additionally:

1. The "Duplication Categories" table restates procedure steps 3–7; keep the table (it's the
   denser encoding) and compress the steps to one line each.
2. Keep fully: "Legitimate Duplication To Accept" (the highest-value section — pure judgment
   policy), dependency-direction warnings in steps 9–10, and the premature-abstraction caveat
   ("three similar lines can beat the wrong abstraction").

### S-10: `find-over-design` — practice what it preaches (~279 → ~150 lines)

The longest skill in the directory is the one about disproportionate design — and it exhibits its
own patterns: a 10-row strategy table, a 7-row patterns table, a 13-step procedure, two report
templates, and a grading rubric, much of it restating the same proportionality idea.

1. Apply X-1, X-3, X-4 as above.
2. **Keep fully:** the complexity-budget concept (step 1), "count consumers per abstraction"
   (step 4), the "Well-Designed Complexity To Accept" list, and the report requirement to list
   *proportional* areas (prevents one-sided over-correction) — these are the skill's real IP.
3. Merge the "Over-Design Patterns" table into procedure steps 4–10 (they enumerate the same
   signals twice); keep whichever encoding is denser per category.

---

## Suggested issue breakdown

Sized per the repo's 2–5-features-per-issue convention:

1. **Issue: Remove obsolete skills and dead references** — S-1 (delete `general`), S-2 items 1–3
   (create-pr dead skill refs + tutorial trim), X-5 (frontmatter normalization). Small, zero-risk.
2. **Issue: Replace imported generic security/review skills** — S-3 + S-4 (decide delete-vs-
   rewrite for `security-audit`; cut `code-review` examples). Needs one product decision (S-3a/b).
3. **Issue: Extract or slim shared audit-skill boilerplate** — X-1 + X-4 across the four audit
   skills. Decide extraction vs slim-in-place first (loader-capability check).
4. **Issue: Strip anti-derailment scaffolding and command recipes** — X-2 + X-3 applied to
   `dead-code-detection`, `sync-docs`, and the `find-*` seeds sections (S-5, S-7, S-8/9/10
   trim items).
5. **Issue (optional, follow-up): Codify repo-specific PR conventions in create-pr** — S-2 "also
   decide" item; needs owner input on desired conventions.

**Validation for all issues:** after each rewrite, run the affected skill once on a
representative task in this repo and diff the report quality against a pre-change run — the
acceptance bar is "same or better findings with the smaller prompt", not merely "shorter".
