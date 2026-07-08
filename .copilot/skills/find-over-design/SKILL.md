---
name: find-over-design
description: 'Find over-engineered, over-abstracted, and over-designed solutions in a codebase. Use when auditing architecture complexity, reviewing premature generalization, checking whether abstractions are justified, assessing docs-to-code ratio, simplifying a codebase, or looking for disproportionate design.'
argument-hint: 'scope, language, suspected area, project size/context, optional risk tolerance'
---

# Find Over-Designed Solutions

## Goal

Find design complexity that is disproportionate to the problem being solved: premature abstractions, excessive indirection, speculative extensibility, over-parameterized interfaces, duplicate implementations, documentation sprawl, and process-heavy automation.

This skill is read-only by default. Report findings and recommendations. Do not modify code unless the user explicitly asks for remediation after the audit.

> Apply the shared audit conventions in `.copilot/skills/_audit-conventions.md` (exclusions, "search broadly / judge narrowly", implementation-usefulness priority decisions using the Fix now / Plan first / Defer-accept grading vocabulary, and the report shape) before auditing. This priority grading is separate from severity, and the priority decision does not override severity.

## When to Use

Use this skill when the user asks to:

- Find over-engineering, over-design, premature generalization, unnecessary abstraction, or needless complexity.
- Review whether an architecture is proportional to the product, team, runtime, and change rate.
- Simplify a codebase before or during a refactor.
- Diagnose why onboarding, small changes, testing, or debugging feels harder than the system warrants.
- Assess documentation, plans, process files, or automation that may outweigh the implementation.
- Check whether abstractions, extension points, factories, wrappers, hooks, or framework layers are justified.

## Core Principle

The goal is proportional design, not minimal design. Some complexity is earned by real requirements: security, reliability, public APIs, deployment constraints, multiple runtimes, compliance, performance, backwards compatibility, team scale, and testability. Flag complexity only when simplification would reduce cognitive load, maintenance cost, or change surface without losing needed capability.

## Procedure

1. Define the complexity budget.
   - Identify what the project actually does, who uses it, how many environments or deployment targets it supports, and how often it changes.
   - Identify hard requirements that justify complexity: external APIs, integrations, multi-tenant behavior, auth/security, reliability, compliance, offline/standalone operation, plugin ecosystems, performance constraints, data migrations, or public backwards compatibility.
   - Establish the expected scale: small script/tool, single service, product feature, platform component, framework/library, infrastructure stack, or enterprise system.
   - Use this budget as the baseline for judging proportionality.

2. Scope and measure.
   - Use the scope provided by the user. If none is provided, inspect entrypoints, core modules, tests, scripts, infrastructure, docs, and customization/automation files relevant to the request.
   - Count or estimate source files, production code lines, test lines, documentation files/lines, configuration files, generated files, and major abstraction layers.
   - For large repositories, measure representative areas and state coverage limits. Do not claim a full architecture audit unless the full requested scope was actually reviewed.

3. Map responsibilities and entrypoints.
   - Start from entrypoints: CLIs, route handlers, app startup, jobs, workers, scripts, workflow files, package exports, plugins, and deployment commands.
   - Trace the main user-visible or system-visible operations through core utilities, wrappers, services, handlers, adapters, and config layers.
   - Note how many files and layers a small change would touch.

4. Inspect abstractions and count consumers.
   - For each abstraction, identify what variation it supports and how many real consumers use that variation.
   - Watch for base interfaces, factories, registries, callbacks/hooks, generic walkers, dependency-injection layers, and framework wrappers.
   - An abstraction with one implementation or two nearly identical consumers is suspicious unless it protects a public API, isolates a dependency, enables testing, or is preparing for a committed near-term requirement.

5. Inspect indirection and call chains.
   - Trace key operations from entrypoint to effect. Count layers that add no validation, transformation, error handling, dependency boundary, observability, retry behavior, or meaningful naming.
   - Flag wrapper functions, pass-through modules, single-use dataclasses, single-use context managers, one-line adapters, and module chains where removing a layer would not lose behavior.
   - Accept indirection when it cleanly isolates external systems, lifecycle management, security checks, telemetry, resource cleanup, or test seams.

6. Inspect parameterization and configurability.
   - Look for optional parameters, callbacks, feature flags, config knobs, strategy objects, or modes.
   - Check call sites. If callers all pass the same values, pass `None`, or use defaults, the interface may be designed for hypothetical flexibility.
   - Accept configurability when it is exercised by real environments, customers, tests that represent real variation, public API guarantees, or deployment constraints.

7. Inspect duplicate and cross-layer implementations.
   - Look for the same behavior implemented in multiple languages, scripts, CI workflows, infrastructure files, docs snippets, or embedded heredocs.
   - Search for comments such as `mirrors`, `same as`, `keep in sync`, `copied from`, `see also`, and `TODO generalize`.
   - Treat dual implementations as high-risk when they must stay synchronized and there is no strong reason they cannot share a source of truth.
   - Accept standalone bootstrap, recovery, migration, or install scripts when importing shared runtime code would defeat their purpose.

8. Inspect documentation, plans, and meta-work.
   - Compare living documentation to implementation size and project complexity.
   - Look for multiple plan files for the same completed feature, stale implementation diaries, historical decision records mixed with active docs, duplicated docs in multiple formats or languages, and process instructions heavier than the task they automate.
   - Accept higher documentation volume for public projects, compliance, onboarding-heavy teams, architecture decisions, runbooks, regulated environments, complex deployments, or long-lived operational knowledge.

9. Inspect enterprise patterns and operational ceremony.
   - Look for scheduling systems, rotation plans, elaborate state files, plugin frameworks, multi-layer observability, governance workflows, approval matrices, and orchestration systems that exceed the actual project scale.
   - Ask whether the current users, maintainers, environments, and failure modes need this ceremony today.
   - Accept operational complexity that directly supports reliability, incident response, security, compliance, or multiple maintainers.

10. Inspect repetitive patterns that indicate the wrong abstraction.
   - Look for three or more functions, commands, handlers, resource finders, tests, or config blocks with identical structure and only data differences.
   - If the difference can be represented as a data row, table-driven code may be simpler than repeated functions.
   - Do not recommend consolidation when repeated code is clearer, when dependency direction would worsen, or when cases are likely to evolve independently.

11. Classify each finding.

| Severity | Criteria |
| --- | --- |
| High | Large abstraction, framework, or dual implementation whose complexity creates real maintenance risk, synchronization risk, or broad change surface with little current use. |
| Medium | Unnecessary indirection, over-parameterized interfaces, stale meta-work, documentation sprawl, or process/operational ceremony that slows common work. |
| Low | Minor single-use types, verbose but correct code, small repeated patterns, or optional simplifications with limited payoff. |
| Accept | Complexity is justified by real requirements, dependency boundaries, security/reliability needs, public API stability, testability, generated structure, or future work that is already committed and near-term. |

12. Recommend a simplification strategy.

| Strategy | Use When |
| --- | --- |
| Inline the abstraction | A wrapper or layer adds no behavior, boundary, naming value, or test value. |
| Collapse layers | A simple operation crosses multiple pass-through modules. |
| Replace with data table | Repeated functions differ only by data. |
| Reduce parameters | Optional knobs, callbacks, or modes are unused or hypothetical. |
| Delete duplicate implementation | Multiple implementations must stay synchronized and can share one source of truth. |
| Keep and cross-reference | Duplication or complexity is intentional but needs a clear pointer to the canonical source or rationale. |
| Trim or archive docs | Historical, duplicate, or stale docs are mixed with living docs. |
| Narrow scope | A generic framework can become a focused helper for current use cases. |
| Document as justified | Complexity is correct but needs a short rationale to prevent repeated debate. |
| Accept no action | Simplification would reduce clarity, break boundaries, or save little. |

13. Report results.
   - Lead with the project scope assessment and complexity budget.
   - Include metrics where available, but do not overstate precision if counts are estimated.
   - List actionable findings ordered by severity and expected simplification payoff.
   - Explicitly list well-designed and proportional areas to prevent one-sided over-correction.
   - Include recommended validation for each possible simplification, especially tests and migration checks.

## Well-Designed Complexity To Accept

- Infrastructure modules that map cleanly to real resource boundaries.
- Security, auth, secret management, audit, and least-privilege controls.
- Observability needed for production diagnosis, SLOs, tracing, or compliance.
- Context managers that manage real cleanup such as temporary directories, locks, transactions, sockets, or connections.
- Interfaces that isolate external services or enable multiple real providers.
- Public APIs, plugin contracts, or extension points with documented consumers.
- Test fixtures and helpers that reduce setup noise while preserving readable tests.
- Configuration layering required by real environments or deployment targets.
- ADRs and runbooks that preserve decisions or operational knowledge still relevant today.

## Common Search Seeds

Adapt these categories to the project language and scope:

- Abstraction and extension signals: interfaces, factories, registries, providers, adapters, strategies, hooks, callbacks, and plugins.
- Pass-through layers: wrappers, base classes, one-line adapters, trivial context managers, and deep chains that add no behavior.
- Sync markers and dual implementations that must stay aligned across source, scripts, CI, IaC, or docs.
- Optional knobs that callers rarely vary: callbacks, modes, strategy options, feature toggles, and kwargs-style interfaces.
- Meta-work and ceremony: plans, roadmaps, handoffs, runbooks, checklists, governance, process, and workflow layers.
- Repetition across sibling files where a table or focused helper may be simpler.


## Implementation-Usefulness Nuance

When an over-design finding is safe to fix immediately, reports may phrase **Fix now** as **Simplify now** to make the action clear.

## Completion Criteria

The audit is complete when the report explains the project's complexity budget, identifies disproportionate complexity with evidence, distinguishes justified complexity from over-design, recommends simplifications with expected payoff, and gives validation steps for any future remediation.
