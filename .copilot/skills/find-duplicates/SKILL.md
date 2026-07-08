---
name: find-duplicates
description: 'Find semantic code and test duplications across a codebase. Use when reviewing duplicate logic, copy-pasted functions, repeated test patterns, DRY violations, cross-language reimplementations, deduplication opportunities, or code smells.'
argument-hint: 'scope, language, suspected files, duplication kind, optional risk tolerance'
---

# Find Semantic Code and Test Duplications

## Goal

Find exact, semantic, structural, and cross-layer duplications in source code, tests, scripts, configuration, and infrastructure code. The purpose is to identify consolidation opportunities, copy-paste risk, and repeated bug surfaces without over-refactoring useful local clarity.

This skill is read-only by default. Report findings and recommendations. Do not modify code unless the user explicitly asks for remediation after the audit.

> Apply the shared audit conventions in `.copilot/skills/_audit-conventions.md` (exclusions, "search broadly / judge narrowly", implementation-usefulness priority decisions using the Fix now / Plan first / Defer-accept grading vocabulary, and the report shape) before auditing. This priority grading is separate from severity, and the priority decision does not override severity.

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
   - For large repositories, sample and index first, then expand around likely duplicate clusters. Do not claim full coverage unless the scan actually covered the full requested scope.

2. Build an inventory.
   - List files by language and role: production source, tests, scripts, infrastructure, examples, generated files, and docs with embedded code.
   - Identify project-native tooling that can help: clone detectors, linters, AST tools, coverage reports, type checkers, test frameworks, and existing task wrappers.
   - Search for explicit sync markers such as `keep in sync`, `copied from`, `duplicate`, `TODO dedupe`, and `shared with`.

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

Adapt these categories to the project language and scope:

- Sync markers that say code mirrors, copies, duplicates, or must stay in step with another location.
- Repeated helpers, factories, fake/mock classes, fixtures, and test setup blocks.
- Embedded code in heredocs, workflow scripts, notebooks, container files, or docs snippets.
- Repeated operational workflows such as backup/restore, deploy, poll/retry, verify, normalize, serialize, or migrate.
- Reused function/helper names across modules; compare bodies and call sites.
- Unusual shared import sets that suggest sibling files implement related behavior.


## Legitimate Duplication To Accept

- Framework-required declarations, decorators, annotations, route signatures, command registration, migration scaffolding, and schema boilerplate.
- Test assertions that look similar but verify different edge cases, failure modes, or public behavior.
- Deliberate test repetition that keeps each test readable in isolation.
- Infrastructure modules with similar shape but materially different resources, lifecycles, or provider requirements.
- Standalone bootstrap, recovery, install, or migration scripts that intentionally avoid importing application dependencies.
- Generated code, vendored code, examples, tutorials, and documentation snippets when they are not part of runtime behavior.
- Two-location duplication where extraction would add coupling or obscure intent.

## Completion Criteria

The audit is complete when duplicate clusters have been reviewed in context, actionable findings are classified by severity, intentional duplication is accepted with rationale, recommendations respect dependency boundaries and local conventions, and any remediation proposal includes validation steps.
