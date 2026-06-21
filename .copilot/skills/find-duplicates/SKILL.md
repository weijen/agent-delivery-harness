---
name: find-duplicates
description: 'Find semantic code and test duplications across a codebase. Use when reviewing duplicate logic, copy-pasted functions, repeated test patterns, DRY violations, cross-language reimplementations, deduplication opportunities, or code smells.'
argument-hint: 'scope, language, suspected files, duplication kind, optional risk tolerance'
---

# Find Semantic Code and Test Duplications

## Goal

Find exact, semantic, structural, and cross-layer duplications in source code, tests, scripts, configuration, and infrastructure code. The purpose is to identify consolidation opportunities, copy-paste risk, and repeated bug surfaces without over-refactoring useful local clarity.

This skill is read-only by default. Report findings and recommendations. Do not modify code unless the user explicitly asks for remediation after the audit.

## When to Use

Use this skill when the user asks to:

- Find duplicate code, duplicate tests, copy-paste logic, repeated helpers, or DRY violations.
- Review a codebase for semantic duplication before refactoring.
- Investigate recurring bugs that may come from multiple implementations of the same behavior.
- Audit test suites for repeated setup, fixtures, or mock patterns.
- Compare scripts against application code for hidden reimplementations.
- Identify consolidation opportunities while preserving intentional duplication.

## Core Principle

Similarity is not automatically a problem. Duplication becomes actionable when changes must be kept in sync, bugs can diverge, behavior is implemented in multiple places, or repeated boilerplate obscures intent. Prefer small, local repetition over abstractions that increase coupling or reduce test readability.

## Procedure

1. Define scope and constraints.
   - Use the scope provided by the user. If none is provided, inspect the workspace structure and focus on source, tests, scripts, config, and infrastructure files that are relevant to the request.
   - Identify languages, frameworks, generated files, vendored code, test directories, examples, scripts, CLIs, build output, and package boundaries.
   - Exclude generated files, vendored dependencies, lockfiles, minified bundles, build output, package caches, virtual environments, and dependency directories such as `.venv/`, `venv/`, `node_modules/`, `dist/`, `build/`, `target/`, `.terraform/`, `.next/`, `.nuxt/`, `coverage/`, and `.git/`.
   - For large repositories, sample and index first, then expand around likely duplicate clusters. Do not claim full coverage unless the scan actually covered the full requested scope.

2. Build an inventory.
   - List files by language and role: production source, tests, scripts, infrastructure, examples, generated files, and docs with embedded code.
   - Identify project-native tooling that can help: clone detectors, linters, AST tools, coverage reports, type checkers, test frameworks, and existing task wrappers.
   - Search for explicit sync markers such as `mirrors`, `same as`, `keep in sync`, `copied from`, `based on`, `duplicate`, `TODO dedupe`, and `shared with`.

3. Detect exact duplicates.
   - Look for identical functions, classes, methods, helpers, shell blocks, SQL queries, config blocks, fixtures, mock setup, and multi-line snippets.
   - Use clone detectors or language-aware tools when available. Fall back to text search, distinctive-line search, and side-by-side comparison.
   - Exact duplicates across three or more locations are usually more actionable than duplicates across two locations.

4. Detect semantic duplicates.
   - Compare code that performs the same steps with different names, literals, resource IDs, message strings, endpoints, plugin names, table names, or test subjects.
   - Mentally replace varying names and literals with parameters. If the remaining algorithm or workflow is the same, classify it as semantic duplication.
   - Check related modules, sibling commands, route handlers, providers, adapters, evaluators, deployment scripts, migration helpers, and repeated test cases.

5. Detect structural duplicates.
   - Look for repeated multi-step workflows such as validate -> transform -> write -> verify, backup -> patch -> restart, create -> poll -> assert, fetch -> normalize -> cache, or setup -> mock -> call -> assert.
   - Repetition may be worth extracting when it has the same failure handling, logging, retries, cleanup, or lifecycle steps in multiple places.
   - Repetition may be acceptable when the repeated shape is framework-required ceremony or when extraction would hide the subject under test.

6. Detect cross-layer and embedded-code duplication.
   - Compare shell scripts, CI workflows, notebooks, heredocs, container files, Terraform/Bicep modules, docs snippets, and application code that appear to perform the same operation.
   - Pay special attention to shell heredocs containing Python, JavaScript, SQL, or YAML that reimplement importable project logic.
   - Cross-language duplication is often legitimate for bootstrapping or standalone recovery scripts, but it should be documented and cross-referenced when it must stay in sync.

7. Detect test duplication.
   - Search for repeated helper names such as `_make_`, `_build_`, `_create_`, `setup_`, `fake_`, and `mock_` across test files.
   - Compare repeated fixture setup, mock patches, factory data, parametrized case shapes, assertions, and scenario builders.
   - Flag test duplication only when it increases maintenance risk or obscures the behavior being tested. Accept deliberate repetition that keeps individual tests clear.

8. Classify each finding.

| Severity | Criteria |
| --- | --- |
| Critical | Large-scale duplication where production behavior must remain synchronized across locations and divergence can cause outages, data loss, security issues, or release-blocking defects. |
| High | Exact or near-exact functions/helpers copied across three or more files, or duplicated core behavior across runtime paths. |
| Medium | Semantic or structural duplicates with meaningful shared workflow but deliberate contextual differences. |
| Low | Minor boilerplate, two-location duplication, repeated setup with low change risk, or cleanup opportunities where extraction is optional. |
| Accept | Duplication is intentional, framework-required, generated, test-readable, standalone by design, or cheaper to keep than to abstract. |

9. Recommend a strategy.

| Strategy | Use When |
| --- | --- |
| Extract shared module | Same implementation is used by multiple callers in the same runtime and dependency direction is clean. |
| Extract helper/function | Repeated small workflow has stable inputs, outputs, and error handling. |
| Parametrize | Test cases or command paths differ only by data, subject, or expected result. |
| Extract fixture/factory | Test setup or mock construction is repeated and obscures test intent. |
| Introduce adapter/interface | Similar implementations exist for multiple providers but need a shared contract rather than a shared function. |
| Keep and cross-reference | Duplication is intentional because scripts must be standalone or layers cannot share runtime dependencies. |
| Document as intentional | Suspicious similarity is correct but future maintainers need to know why. |
| Accept no action | Extraction would add coupling, reduce readability, or create premature abstraction. |

10. Check existing abstractions before recommending new ones.
   - Search for existing helpers, fixtures, factories, clients, adapters, service layers, task wrappers, config loaders, and utilities that already cover the duplicated behavior.
   - Prefer extending or reusing established local patterns over creating a parallel abstraction.
   - Check dependency direction before recommending extraction. Do not suggest importing production code into standalone bootstrapping scripts if that would break their purpose.

11. Report results.
   - Lead with actionable duplication clusters, ordered by severity and blast radius.
   - Include accepted patterns after actionable findings with concise rationale.
   - For each finding, include file references, similarity type, evidence, risk, recommended strategy, and validation steps.
   - State scan coverage and limits clearly, especially for large repositories or dynamic languages.

## Duplication Categories

| Type | Description | Typical Evidence |
| --- | --- | --- |
| Exact duplicate | Identical or nearly identical block copied across files. | Same function body, helper, fixture, shell block, query, or config stanza. |
| Semantic duplicate | Same behavior with different names, literals, subjects, or resource IDs. | Same algorithm or workflow after replacing varying values with parameters. |
| Structural duplicate | Same multi-step pattern repeated with different implementation details. | Repeated lifecycle, error handling, retries, setup, or teardown shape. |
| Cross-layer duplicate | Same behavior reimplemented across languages, scripts, CI, IaC, docs, or app code. | Shell heredoc mirrors source module; CI YAML repeats deploy script logic. |
| Test duplicate | Same fixture, mock setup, test body, or assertion pattern repeated. | Repeated `_make_*` helpers, repeated patch lists, similar test cases. |

## Common Search Seeds

Adapt these to the project language and scope:

- Sync markers: `mirrors|same as|keep in sync|copied from|based on|duplicate|dedupe|shared with|see also`
- Repeated helpers: `def _make_|def _build_|def _create_|function make|function build|class Fake|class Mock`
- Test setup: `mocker\.patch|monkeypatch|pytest\.fixture|@pytest\.mark\.parametrize|jest\.fn|sinon\.stub|beforeEach`
- Embedded code: `<< ?['\"]?EOF|python - <<|python3 - <<|node - <<|cat <<|script: \|`
- Repeated workflows: distinctive operational verbs such as `backup`, `restore`, `patch`, `restart`, `deploy`, `poll`, `retry`, `verify`, `normalize`, `hydrate`, `serialize`, and `migrate`.
- Function names: search for the same private helper or public function name across modules, then compare bodies and call sites.
- Imports: files with the same unusual set of imports often implement related or duplicated behavior; compare their main workflow.

## Legitimate Duplication To Accept

- Framework-required declarations, decorators, annotations, route signatures, command registration, migration scaffolding, and schema boilerplate.
- Test assertions that look similar but verify different edge cases, failure modes, or public behavior.
- Deliberate test repetition that keeps each test readable in isolation.
- Infrastructure modules with similar shape but materially different resources, lifecycles, or provider requirements.
- Standalone bootstrap, recovery, install, or migration scripts that intentionally avoid importing application dependencies.
- Generated code, vendored code, examples, tutorials, and documentation snippets when they are not part of runtime behavior.
- Two-location duplication where extraction would add coupling or obscure intent.

## Report Template

````markdown
## Duplication Audit: <scope>

**Overall:** <clean | minor duplication | needs attention | high-risk duplication>
**Coverage:** <full requested scope | targeted scan | sampled scan with limits>
**Findings:** <N critical, N high, N medium, N low, N accepted>

### Findings

| ID | Sev | Type | Files | Description |
| --- | --- | --- | --- | --- |
| DUP-1 | High | Exact | a.py, b.py, c.py | `helper()` copied across three modules. |
| DUP-2 | Medium | Cross-layer | module.py, script.sh | Deployment logic reimplemented in shell and source code. |
| TDUP-1 | Low | Test helper | test_a.py, test_b.py | Similar setup helper repeated in two test files. |

### Details

#### DUP-1: <title>

**Files:** `a.py:14-19`, `b.py:37-42`, `c.py:14-19`
**Type:** Exact duplicate
**Severity:** High

```python
# representative duplicated snippet
```

**Evidence:** <why these are duplicates>
**Risk:** <what can diverge or become harder to maintain>
**Recommended strategy:** <extract shared module | parametrize | keep and cross-reference | accept>
**Validation:** <tests, lint, or review steps if this is later fixed>

### Accepted Patterns

- `tests/test_example.py:20-45` — repeated assertions cover different public edge cases and are clearer left local.
- `scripts/bootstrap.sh:10-80` — standalone script duplicates setup logic intentionally because it runs before project dependencies exist.

### Optional Remediation Plan

Create a plan only if the user asks to fix the findings or if the duplication is broad enough to need phased remediation. Use repository-local planning conventions when present; otherwise provide the plan inline.
````

## Remediation Plan Template

Use this template only after the user asks for fixes or approves remediation planning.

````markdown
# Plan: Deduplicate <topic>

## Background

Duplication findings DUP-X, DUP-Y, and TDUP-Z identified <summary of duplicated behavior and risk>.

## Phase 1: <title>

**Scope:** <files and behavior>
**Strategy:** <extract shared module | fixture | parametrization | cross-reference>
**Files to change:**

- Edit: `path/to/file.ext`
- Edit: `path/to/test_file.ext`

**Current duplicated shape:**

```<language>
# representative current code
```

**Proposed shape:**

```<language>
# representative proposed code
```

**Risks:** <dependency direction, readability, public API, test clarity>

## Test Impact

- `tests/test_example.ext` — update setup to use shared fixture.
- Add or keep coverage for each distinct behavior after extraction.

## Verification

1. `<targeted test command>`
2. `<lint/type/build command if relevant>`
````

## Completion Criteria

The audit is complete when duplicate clusters have been reviewed in context, actionable findings are classified by severity, intentional duplication is accepted with rationale, recommendations respect dependency boundaries and local conventions, and any remediation proposal includes validation steps.