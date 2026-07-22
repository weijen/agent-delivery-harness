---
title: Issue 65 Over-Design Review
description: Fresh-context review of whether issue 65 is meaningful or disproportionate on current origin/main
---

## Research Questions

* What risk is already covered by current sensors?
* Which issue 65 acceptance criteria duplicate existing sensors?
* Which requirements lack an authoritative schema or real corpus examples?
* Is a new manifest or scorecard integration proportionate?
* What correctness risks arise from applying one schema to both `SKILL.md` and `.agent.md`?
* Should issue 65 be kept as-is, narrowed, or closed, and what is the minimum revised scope and exact validation approach?

## Scope And Evidence

Reviewed refreshed `origin/main` at `2bced33d3188481e361190e5dae0787a6ee6de31`. The local branch remained two commits behind and was not checked out or changed. Evidence included issue 65 and its comment, every requested repository file, all nine skill and three agent frontmatter blocks, the L0 runner and manifests, official Agent Skills and VS Code custom-agent documentation, and relevant history from `84f8702` through `8233c59` and `79d14c2`.

External schema sources:

* [Agent Skills specification](https://agentskills.io/specification)
* [VS Code Agent Skills](https://code.visualstudio.com/docs/copilot/customization/agent-skills)
* [VS Code custom agents](https://code.visualstudio.com/docs/copilot/customization/custom-agents)

## Findings

| Severity | Priority | Finding |
|----------|----------|---------|
| Warning | Fix now by narrowing | One shared schema for `SKILL.md` and `.agent.md` is incorrect. Skill names are required, directory-derived, limited to 64 characters, and restricted to lowercase alphanumerics plus hyphens. Agent frontmatter is optional, `name` is optional with filename fallback, and the current VS Code contract publishes no equivalent directory-match, charset, namespace, or 64/1024 limits. |
| Warning | Defer-accept | A new manifest and scorecard path is disproportionate. The direct workflow already blocks, `tests/evals/manifests/skills/` is empty, and `run-l0-suite.sh` discovers only `manifests/scripts/l0-*.json`. `run-evals.sh` also collapses ordinary grader diagnostics to `target_failure` and an exit code, losing the issue's required specific reason. |
| Info | Fix now by narrowing | The meaningful uncovered risk is generic skill schema drift. The official VS Code skill contract confirms silent non-loading for invalid names, directory mismatch, namespace prefixes, and over-limit metadata. Current CI only checks opening and closing `---` fences. |
| Info | Defer-accept | Several acceptance criteria duplicate shipped sensors. The workflow and `tests/scripts/test_harness_smoke.sh` already gate frontmatter fences for all skills and agents. `tests/meta/test_skill_references_resolve.sh` checks the concrete dangling skill references and pins `code-review` kebab-case. Other sensors pin folder/name agreement for `security-audit`, `code-review`, and `public-exposure-audit`, plus the generator agent's exact identity. |
| Info | Plan first | Reference validation is underspecified. The skill contract describes relative paths from the skill root and VS Code examples use Markdown links. The corpus also uses code-span repository paths such as `.copilot/skills/_audit-conventions.md`, while agents use Markdown links such as `../skills/find-over-design/SKILL.md`. A linter must define which syntax is machine-resolved and whether cross-skill references are allowed. |

### Risk Already Covered

* `.github/workflows/harness-smoke.yml` lines 46-62 blocks malformed or missing frontmatter fences across every checked-in skill and agent.
* `tests/scripts/test_harness_smoke.sh` lines 12-26 independently runs the same fence check against the current corpus.
* `tests/meta/test_skill_references_resolve.sh` lines 49-65 checks the concrete dead-reference regression from issue 177 and the formerly malformed `code-review` name.
* `tests/meta/test_imported_skills_repo_scoped.sh` lines 17-23 checks directory/name agreement for two skills. `tests/meta/test_public_exposure_audit_skill.sh` lines 22-28 and `tests/meta/test_generator_role_contract.sh` lines 30-37 add asset-specific frontmatter checks.
* `docs/evaluation/meta-test-triage.md` lines 12-17 and 82 explicitly classify parsed skill/agent frontmatter and file-reference resolution as structural sensors worth keeping.

### Duplicate Acceptance Criteria

* "Deterministic lint validates skills and agents" duplicates the existing fence gate, but only at a basic level.
* "Referenced relative files exist" partially duplicates the concrete `create-pr` and deleted-`general` checks from issue 177. It does not yet provide a generic link checker.
* "Current checked-in assets pass" duplicates the current positive-only workflow and smoke sensor.
* "Tier A blocking CI" already exists as a direct workflow step. A second L0-style gate is not needed to make the check blocking.
* Name matching is spot-covered for four concrete assets, not generically covered for all nine skills.
* Description presence/length, generic charset/length, namespace rejection, and malformed negative fixtures are not covered.

### Authority And Corpus Gaps

* Skill name, namespace, and description limits do have current authority in the official VS Code Agent Skills contract and Agent Skills specification. The backlog should cite and version that contract rather than invent values.
* Equivalent agent limits do not have authority. VS Code documents an optional agent header and optional `name` with filename fallback. Applying skill rules to agents creates false failures and may prohibit valid display names or omitted names.
* "Referenced relative files" lacks a grammar. Markdown links are authoritative examples; backtick paths and prose references are not specified as machine-resolved references.
* No current skill demonstrates a namespace, illegal character, directory mismatch, absent description, or near-limit value. The largest current name is 21 characters and the largest description is 505 characters. Negative fixtures would prove the sensor, but not demonstrate a second adopter's need.
* The `blocked-on-second-adopter` label is consistent with the corpus evidence: there is one historical malformed name and one family of dead references, both already fixed and pinned by commit `8233c59`.

### Historical Evidence

* Commit `fa6ea82` introduced the basic fence check on 2026-06-22.
* Commit `84f8702` introduced 1,141 lines of L0/L1 design, and `d920763` later pivoted the first runnable L1 target toward `create-pr` artifacts.
* Commits `c009529` and `265e410` implemented the manifest, runner, scorecard, and five script-only L0 manifests. They did not add a skills manifest or generic L1 suite discovery.
* Commit `8233c59` fixed the only documented malformed skill name, removed dead skill references, and added `test_skill_references_resolve.sh`.
* Commit `79d14c2` removed 1,644 lines of low-value meta-test ceremony and retained frontmatter/reference checks specifically because they parse structure. This supports one focused structural sensor, not an additional reporting stack.

## Recommended Scope And Validation

Verdict: **NARROW**.

Retain one capability: prevent a checked-in skill from silently failing discovery under the official VS Code Agent Skills contract. Do not market the same rules as an agent schema, and do not add a manifest or scorecard until a second consumer needs comparable case-level reporting.

Minimal scope:

1. Replace the inline workflow fence block with one reusable linter invocation over `.copilot/skills/*/SKILL.md`.
2. For skills only, enforce a parseable frontmatter block, required `name`, exact parent-directory match, 1-64 characters, `^[a-z0-9]+(-[a-z0-9]+)*$`, required nonempty `description`, and 1-1024 characters.
3. Reject slash, colon, dot, leading/trailing hyphen, and consecutive hyphens through the same name rule, but emit stable reason tokens such as `namespace_prefix`, `invalid_name`, and `name_mismatch`.
4. Check only relative Markdown-link targets, ignoring URLs, anchors, and tool references. Resolve a skill link from the skill root and an agent link from the agent file directory. Do not infer references from code spans or arbitrary prose.
5. Keep agent handling separate: preserve the existing fence check for this repository and validate relative Markdown links, but do not require agent `name`, match it to the filename, or apply skill length/charset/namespace rules.
6. Add one negative-fixture sensor that creates temporary skills and asserts exact reason tokens for mismatch, illegal characters, namespace prefix, missing description, over-limit values, and dangling Markdown links. Include one valid agent with omitted `name` to prevent accidental skill-schema reuse.
7. Wire the reusable linter directly into `harness-smoke.yml`; the nonzero exit is the Tier A block. Update `test_harness_smoke.sh` to assert that single invocation and remove duplicated inline parsing.

Exact validation:

* Run the linter against all current skills and agents and require exit 0.
* Run each temporary malformed fixture independently and require exit 1 plus its exact stable reason token and file path.
* Mutation-check one valid current skill by changing its name to `org/code-review`, and require `namespace_prefix`.
* Mutation-check one current agent by removing `name`, and require success because filename fallback is valid.
* Run the focused fixture sensor, `bash tests/scripts/test_harness_smoke.sh`, `bash -n` on the linter and sensor, and the repository's exact CI `shellcheck` glob.
* Do not add `tests/evals/manifests/skills/*.json`, modify `run-l0-suite.sh`, or emit a scorecard for this issue.

## Follow-On Questions

No blocking clarifying question remains. Before implementation, select and pin the exact upstream VS Code Agent Skills contract date or version in the linter's test comments so future schema changes are deliberate.
