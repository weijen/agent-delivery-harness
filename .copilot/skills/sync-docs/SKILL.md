---
name: sync-docs
description: 'Audit documentation against the current codebase and fix stale factual references. Use when after refactoring, adding/removing files or commands, changing architecture, renaming paths, updating setup flows, or doing periodic documentation hygiene.'
argument-hint: 'scope, docs path, source path, changed area, optional live checks, optional edit policy'
---

# Sync Documentation with Codebase

## Goal

Audit documentation against the current codebase, then fix stale factual references such as file paths, command names, setup steps, repo structure trees, configuration keys, architecture claims, and counts.

This skill may edit documentation by default, but only to correct factual drift. Do not rewrite voice, reorganize sections, or expand documentation beyond the requested sync unless the user asks.

## When to Use

Use this skill when the user asks to:

- Sync docs with code, update stale docs, or run documentation hygiene.
- Check documentation after refactoring, renaming, adding, or removing files.
- Update docs after changing commands, setup flows, configuration, infrastructure, routes, APIs, plugins, tools, or architecture.
- Verify links, paths, repo trees, command examples, test counts, generated artifacts, and customization files.
- Audit docs before release, handoff, or onboarding.

## Core Principle

Treat code, configuration, build scripts, tests, generated manifests, and live systems as sources of truth. Treat docs as claims that must be verified. Fix precise factual drift; preserve historical narrative, prose style, and author intent.

## Procedure

1. Define scope and edit policy.
   - Use the documentation scope provided by the user. If none is provided, inspect common documentation roots such as `README*`, `docs/`, `.github/`, `.devcontainer/`, `CONTRIBUTING*`, `SECURITY*`, `CHANGELOG*`, package docs, and customization files.
   - Identify code/config sources of truth relevant to the docs: source files, tests, scripts, CLI help, task runners, package manifests, config schemas, infrastructure files, API schemas, route definitions, generated manifests, and deployment outputs.
   - Determine whether the request is audit-only or fix-and-report. If unclear, default to fixing unambiguous factual drift in living docs and reporting ambiguous items.
   - Respect repository-specific doc policies if present.

2. Classify documentation tiers.

| Tier | Treatment | Examples |
| --- | --- | --- |
| Tier 1: Living docs | Full factual audit. Auto-fix unambiguous stale references and incorrect factual claims. | README, active setup guides, architecture docs, operations docs, active skill/customization docs, devcontainer docs, docs indexes. |
| Tier 2: Historical docs | Link/path integrity only. Fix broken links and renamed paths, but do not update prose to later state. | Archived implementation notes, completed plans, old design snapshots, migration records. |
| Tier 3: Published/immutable docs | Surface-only. Report broken references or stale claims; do not edit. | Published blog snapshots, release notes preserved as artifacts, external-facing frozen docs, legal/compliance records. |

If the repository has its own archive or published-doc conventions, use those. If not, infer from folder names such as `archive/`, `archived/`, `historical/`, `plans-completed/`, `blog/`, `blogs/`, `release-notes/`, and `snapshots/`.

3. Build the source-of-truth inventory.
   - Inventory files in scope, excluding generated/vendor/build/dependency directories such as `.git/`, `.venv/`, `venv/`, `node_modules/`, `dist/`, `build/`, `target/`, `.terraform/`, `.next/`, `.nuxt/`, `coverage/`, caches, lockfiles when irrelevant, and generated outputs.
   - Inventory commands from project-native sources: `README`, task runners, package scripts, CLI `--help`, Makefiles, Taskfiles, npm/pnpm/yarn scripts, Python entry points, console scripts, shell scripts, route listings, and workflow files.
   - Inventory config keys and schemas from typed config models, JSON/YAML schemas, examples, templates, environment variable loaders, and defaults.
   - Inventory tests from the project-native test collector when practical.
   - Inventory infrastructure resources from Terraform, Bicep, ARM, CloudFormation, Kubernetes manifests, Helm charts, Docker Compose files, CI/CD definitions, or deployment manifests used by the repo.
   - Capture commands that were run and commands that could not run, so the report is reproducible.

4. Run optional live probes only when relevant and safe.
   - Some claims are verifiable only against a live environment, such as deployed resource names, model versions, feature flags, plugin allow-lists, installed extensions, API routes, health checks, or production config.
   - Run live probes only if the user requested them, the repo clearly documents safe read-only commands, or credentials/session state are already available.
   - Live probes must be read-only. Skip gracefully when credentials, network access, permissions, or environment variables are unavailable, and record the skip reason.
   - Never let live state silently override desired-state source files. Report drift between desired state and live state separately.

5. Audit high-rot documentation claims first.

| Claim Type | How to Verify |
| --- | --- |
| File paths and links | Resolve relative links and code paths against the current workspace inventory. |
| Repository tree diagrams | Compare listed files/directories against actual tree output for the documented scope. |
| CLI commands and options | Compare examples against CLI help, task scripts, package scripts, command modules, or documented entrypoints. |
| Setup commands | Check package manager, virtual environment, task runner, container, and environment variable flows against current project files. |
| Test counts or test commands | Compare against test collector output or project task definitions. |
| Config keys/env vars | Compare against schemas, config classes, examples, and loaders. |
| Architecture/resource claims | Compare against source modules, route definitions, IaC, deployment manifests, ADRs, or live read-only probes when appropriate. |
| Generated artifact names | Compare against build outputs or generation scripts only when generated files are tracked or expected. |
| Tool/skill/customization docs | Validate frontmatter, names, triggers, paths, commands, and workflow instructions. |
| Archive status | Check whether active plans or TODO docs describe work that has already shipped. |

6. Audit customization and skill files when present.
   - For `SKILL.md`, prompt, instruction, agent, and similar customization files, verify structural sanity as documentation that drives agent behavior.
   - Check that required frontmatter exists, the `name` matches its folder or file convention, descriptions include useful trigger phrases, paths and commands are current, and the body is actionable.
   - Use semantic judgment. Do not flag examples inside fenced code blocks as unfinished instructions, and do not treat regex examples as stale prose.
   - Auto-fix unambiguous structural issues such as a name/folder mismatch or broken path. Flag wording and workflow-quality issues for user review when the right fix requires judgment.

7. Fix unambiguous stale references.

| Issue | Action |
| --- | --- |
| Deleted or renamed file path | Update to the replacement path if clear; otherwise remove the broken reference or flag it. |
| Broken relative link | Correct link target and relative depth. |
| Outdated repo tree | Regenerate only the documented tree section while preserving surrounding prose. |
| Removed or renamed command | Update to replacement command if clear; otherwise flag for review. |
| New command/file missing from an active index | Add it only when the index is intended to be exhaustive. |
| Stale setup command | Update to current package manager/task runner flow. |
| Outdated config key/env var | Update to current schema or example. |
| Completed active plan | Mark complete or move/archive only when repository conventions make this unambiguous. |
| Architecture claim contradicted by source | Update factual claim when source of truth is clear; otherwise flag. |
| Hardcoded workspace or machine path | Replace with repo-relative path, variable, or current workspace path only if the doc intentionally needs an absolute path. |

Editing rules:

- Preserve original formatting, headings, order, and prose style.
- Make the smallest factual edit that repairs the stale claim.
- Do not add new sections, broaden scope, or rewrite explanatory content unless requested.
- Do not edit Tier 3/published immutable docs.
- For Tier 2/historical docs, fix only broken links or path navigation, not historical claims.
- If a fix could affect runtime behavior, credentials, deployment, legal/compliance text, or public API commitments, flag it instead of auto-fixing.

8. Verify the fixes.
   - Re-search for stale strings that were replaced in living docs.
   - Re-check corrected links and file paths.
   - Re-run any lightweight command inventory or link checker that was used before, when practical.
   - If stale strings remain in Tier 3 docs, report them as surface-only findings.
   - If stale strings remain in Tier 2 docs and they are historical prose rather than link/path breakage, report that they were intentionally left unchanged.

9. Report ambiguous items needing review.
   - List docs whose correctness depends on product decisions, live environment state, credentials, deployment access, legal/compliance wording, or undocumented source-of-truth conflicts.
   - List commands that could not be run and why.
   - List live probes skipped and why.

10. Produce the final report.
   - Summarize counts by tier: files audited, files edited, fixes applied, up-to-date files, and skipped files.
   - Include live probe status if relevant.
   - Include customization/skill structural review status if relevant.
   - Highlight key changes and remaining manual-review items.

## Common High-Rot Patterns

- Hardcoded workspace, user, home, checkout, or container paths.
- ASCII repository trees and file inventories.
- Command lists, CLI examples, task runner commands, package scripts, and flags.
- Test counts, coverage percentages, benchmark numbers, and performance claims.
- Setup instructions that mention old package managers, virtual environment activation, ports, environment variables, or service names.
- Architecture diagrams or prose that list resources, routes, components, plugin names, model names, queue/topic names, database tables, or security boundaries.
- Documentation indexes that claim to list every guide, skill, command, scenario, or module.
- Archived plans that still appear active after implementation shipped.
- Skills/customization files that reference removed commands, renamed paths, stale workflow assumptions, or missing frontmatter.
- Stale model-pin frontmatter: a `model:` key in agent/skill frontmatter that names a retired model generation. An unknown pin either silently falls back to a default model or fails to launch, both invisible to the caller. Prefer inheriting the session model (no pin) unless a pin is deliberately maintained against a current, verified model id.

## Useful Inventory Commands

Adapt these to the project. Prefer repository-native commands when available.

```bash
# File inventory, excluding common noise
rg --files -g '!**/.git/**' -g '!**/.venv/**' -g '!**/venv/**' -g '!**/node_modules/**' -g '!**/dist/**' -g '!**/build/**' -g '!**/target/**' -g '!**/.terraform/**' -g '!**/coverage/**'

# Markdown/docs inventory
rg --files -g '*.md' -g '*.mdx' -g '!**/node_modules/**' -g '!**/.git/**'

# Path-like references in docs
rg '([A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+' README* docs .github 2>/dev/null

# Workspace-specific absolute paths
rg '<absolute-local-path-patterns>' README* docs .github .devcontainer 2>/dev/null

# Common stale setup patterns
rg 'source .*activate|pip install|npm install|yarn install|pnpm install|uv run|make |task |docker compose' README* docs .github .devcontainer 2>/dev/null
```

## Report Template

````markdown
## Docs Sync Report: <scope>

### Summary

Docs sync complete.

| Area | Result |
| --- | --- |
| Tier 1 living docs | <X audited, Y edited, Z fixes, N up to date> |
| Tier 2 historical docs | <X checked, Y link/path fixes, Z left as historical prose> |
| Tier 3 immutable docs | <X scanned, Y findings reported, 0 edited> |
| Live probes | <ran | skipped: reason | not applicable> |
| Customization/skill review | <N checked, M fixed, K flagged> |

### Key Changes

- `<file>` — <one-line factual fix>.
- `<file>` — <one-line factual fix>.

### Manual Review Needed

- `<file>` — <ambiguous claim, skipped live check, immutable-doc erratum, or judgment-based issue>.

### Verification

- `<command or check>` — <result>.
- `<command or check>` — <result>.
````

## Completion Criteria

The task is complete when living docs have been checked against current source-of-truth inventory, unambiguous stale references have been fixed, historical and immutable docs have been handled according to tier policy, skipped or ambiguous checks are reported, and verification confirms the specific stale strings or broken references addressed by the sync.