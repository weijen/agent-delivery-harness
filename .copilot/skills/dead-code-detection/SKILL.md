---
name: dead-code-detection
description: 'Detect dead code, unreachable code, unused symbols, semantically unreachable branches, referenced-but-never-called code, zombie paths, stale feature flags, and oxbow code. Use when asked to find dead code, unreachable code, code that is referenced but cannot execute, unused functions/classes/modules, cleanup candidates, or removal safety.'
argument-hint: 'scope, language, suspected files, entrypoints, runtime commands, optional risk tolerance'
---

# Dead Code Detection

## Goal

Find code that is dead in more than one sense:

- Unused definitions: functions, classes, methods, modules, imports, variables, exports, routes, commands, or config entries with no remaining legitimate reference.
- Syntactically unreachable code: statements after unconditional `return`, `raise`, `throw`, `break`, `continue`, impossible loops, constant-false branches, duplicate cases, or compiler/type-checker proven unreachable paths.
- Semantically unreachable code: code that is referenced somewhere but cannot be reached from real runtime entrypoints because no execution path, configuration, feature flag, route, dependency injection binding, state machine transition, role, platform, or dispatch path can call it.
- Dynamically dead code: code not executed by representative tests, evals, traces, telemetry, or branch coverage, especially when static references exist only through wrappers, registries, mocks, tests, migrations, or obsolete adapters.
- Oxbow code: retained legacy compatibility or historical code that may still be intentionally shipped; classify separately instead of deleting by default.

> Apply the shared audit conventions in `.copilot/skills/_audit-conventions.md` (exclusions, "search broadly / judge narrowly", implementation-usefulness priority decisions using the Fix now / Plan first / Defer-accept grading vocabulary, and the report shape) before auditing. This priority grading is separate from severity, and the priority decision does not override severity.

## When to Use

Use this skill when the user asks to detect, audit, remove, review, or explain:

- dead code, unused code, stale code, unreachable code, zombie code, oxbow code
- referenced code that is never called at runtime
- feature-flag branches that can no longer execute
- obsolete routes, commands, tools, plugins, handlers, services, migrations, config keys, or adapters
- cleanup candidates before refactors or after migrations
- whether it is safe to delete a code path

## Core Principle

Treat dead-code detection as evidence gathering, not a single-tool verdict. Static unused-symbol tools find name-level clues; reachability requires control-flow, data-flow, entrypoint, configuration, runtime, and test/telemetry evidence. Do not recommend deletion unless the finding has a clear reason, a verified absence of legitimate entrypoints, and a validation path.

## Procedure

1. Define scope and risk.
   - Identify language, packages, deploy targets, public APIs, generated/vendor files, tests, scripts, CLIs, workers, scheduled jobs, route handlers, plugin registries, config files, migrations, and feature flags.
   - Ask only if the scope or deletion risk is unclear. Otherwise infer from the repo and continue.
   - Decide whether the task is audit-only, remove candidates, or actually delete code.

2. Inventory runtime entrypoints.
   - List application startup files, routes, CLIs, job schedulers, message/queue handlers, plugin registration, dependency injection containers, framework decorators, config-driven handlers, and `__main__` or package exports.
   - Include non-production entrypoints separately: tests, evals, examples, migrations, benchmarks, admin scripts, and generated clients.
   - Mark public API surfaces and extension points as protected until proven internal.

3. Run project-native checks first.
   - Use the repo's existing lint, type, build, and test commands before introducing new tools.
   - Inspect config for enabled rules such as unreachable-code, unused exports, no-unused-vars, dead-code, tree-shaking, strict type checking, or branch coverage.
   - For Python, prefer existing `ruff`, `pyright`, `mypy`, `pylint`, `vulture`, `coverage`, or project task wrappers if present.
   - For TypeScript/JavaScript, prefer existing `tsc`, ESLint `no-unreachable`/unused rules, `ts-prune`, `knip`, bundler tree-shaking reports, and coverage.
   - For compiled languages, prefer compiler warnings, link-time unused reports, static analyzers, and coverage tooling already configured.

4. Keep tool execution simple and recoverable.
   - Prefer direct, project-native commands over clever shell one-liners. Complex validation commands can fail because of quoting, shell differences, missing dependencies, or tool-output capture issues.
   - If a command fails or returns no retrievable output, do not keep retrying the same shape. Simplify it once, then switch to a different evidence source such as reading the file, using the editor diagnostics, or running the underlying tool directly.
   - If a search helper or subagent reports plausible files with invalid root paths such as `/src/...` or `/config.yaml`, treat that as a path-resolution problem rather than evidence about the code. Re-read the same targets using workspace-relative paths or known absolute workspace paths.
   - Distinguish command execution failure from analysis failure. If a validation command cannot report output, state that the command result was unavailable and validate the workflow through another reliable path.
   - For customization files such as `SKILL.md`, validate by checking the file exists, reading the frontmatter, confirming required fields, and checking the body has actionable steps. A shell YAML parser is optional, not the only source of truth.
   - Capture exact commands that worked and commands that could not be run so the final report is reproducible.

5. Static pass: unused definitions and impossible syntax.
   - Search definitions and references with language-aware tools when available; fall back to `rg` only as a clue.
   - Look for unused imports, private methods, unexported helpers, local variables, duplicate conditions, impossible pattern matches, always-true/false guards, code after unconditional terminators, and unreachable exception or match cases.
   - In Python, useful checks include `vulture --min-confidence 100`, `mypy --warn-unreachable`, Pylint `unreachable`, and coverage branch reports. Lower-confidence Vulture findings need manual review because dynamic dispatch and decorators often create false positives.
   - Separate test-only reachability from production reachability. Code referenced only by tests may still be production dead.

6. Semantic reachability pass: referenced but never callable.
   - Build a call/dispatch map from real entrypoints to candidate code.
   - Trace decorators, routing tables, DI registration, plugin/config registration, event names, queue topics, command names, RPC endpoints, state machine transitions, strategy maps, feature flags, environment gates, and platform gates.
   - For each suspicious referenced symbol, answer: who can call it, under what runtime condition, with what config value, in which deployment target, and through which user/system action?
   - Flag code as semantically dead when references are only from unreachable parents, obsolete registries, tests/mocks, docs/examples, migration shims no longer invoked, disabled flags with no enabling path, or fallback branches whose preconditions cannot occur.

7. Dynamic evidence pass.
   - Run representative tests, evals, integration flows, or smoke tests with statement and branch coverage if available.
   - Use branch coverage to find partial branches where statement coverage is green but one branch destination is never taken.
   - Compare coverage gaps against entrypoint and config analysis. Low coverage alone is not dead-code proof; it is a prompt to inspect runtime paths.
   - When available, inspect production telemetry, route access logs, tracing spans, feature-flag analytics, command metrics, or plugin invocation counts. Treat lack of telemetry as supporting evidence only after verifying instrumentation coverage.

8. Classify each finding.
   - `Confirmed dead`: no legitimate static reference and no runtime entrypoint; or syntactically unreachable by language/compiler rules.
   - `Semantically unreachable`: referenced, but all callers are unreachable, disabled, obsolete, test-only, or blocked by impossible config/state.
   - `Probably dead`: strong static/dynamic evidence but one unresolved dynamic mechanism remains.
   - `Oxbow/intentional`: legacy, compatibility, regulatory, migration, generated, public API, or extension-point code retained intentionally.
   - `False positive`: framework magic, reflection, dynamic import, serialization, decorators, DI, external callers, public API, generated code, or operational script explains reachability.

9. Verify before deletion.
   - For confirmed candidates, remove in the smallest coherent slice and run targeted tests, type checks, lint, and build commands.
   - Also run any affected integration/eval/smoke test that covers the entrypoint or feature area.
   - If deletion touches public API, config schema, database migrations, infrastructure, auth, security, or external integrations, escalate risk and ask before proceeding.
   - Do not delete oxbow/intentional code unless the user explicitly approves the product or compatibility decision.

10. Report results.
   - Lead with high-confidence findings and exact file/function references.
   - For each finding include classification, evidence, likely impact, suggested action, and validation command.
   - Group unresolved suspects separately from deletion-ready findings.
   - Mention tool limits and false-positive risks, especially for dynamic languages and framework-driven code.

## Evidence Checklist

For each candidate, collect as many as apply:

- Static tool output or compiler/type-checker warning
- Definition location and all references
- Runtime entrypoint chain, or absence of one
- Config/feature-flag/deployment condition that enables or blocks it
- Coverage or branch coverage evidence
- Telemetry/log/trace evidence if available
- Tests or smoke flows run after proposed removal
- Reason it is not generated/vendor/public compatibility code

## Implementation-Usefulness Nuance

For dead-code findings, **Fix now** means **Delete now** only when evidence is conclusive, removal is bounded, and validation is clear; otherwise use **Plan first** or **Defer-protect**.

**The decision does not override classification or evidence.** A high usefulness score
never licenses an unsafe deletion. **Default to Defer-protect** for public APIs, exported
symbols, extension points and plugin seams, migration/compatibility paths, and
generated/vendored code — these stay even when they look locally unused, unless removal is
explicitly in scope and externally confirmed. When evidence is weak, prefer Defer-protect
over Delete now.

## Common Patterns To Inspect

- Code after unconditional terminators
- `if False`, `while False`, impossible enum/literal branches, duplicate `case` or `elif` checks
- Feature flags permanently disabled, removed, or never configured true
- Fallback providers after a resolver that always returns or raises
- Handler maps containing keys never used by router/event names
- Strategies registered but never selected by config or request values
- Old adapters behind a migration selector that no longer selects them
- Test fixtures or mocks that are the only callers of production functions
- Public exports that are not used internally but may be external API
- Framework callbacks invoked by decorators, naming conventions, reflection, serialization, dependency injection, or plugin loading

## Tool Notes

- `rg` proves textual presence or absence, not semantic reachability.
- Unused-symbol tools are conservative or heuristic; dynamic dispatch creates false positives and string-based calls create false negatives.
- Branch coverage can reveal missing runtime paths even when statement coverage appears complete.
- Type-checker unreachable warnings are strong evidence for impossible branches but depend on annotation quality and configured strictness.
- Do not treat low coverage alone as dead code; classify it as unexercised until entrypoints and runtime conditions are analyzed.

## Completion Criteria

The task is complete when the response distinguishes confirmed dead code from suspects, explains referenced-but-unreachable paths, identifies intentional/oxbow code, and gives concrete next actions with verification steps. If code was removed, the relevant checks must have been run or the reason they could not run must be stated.
