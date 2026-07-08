---
name: find-brute-force
description: 'Find brute-force fixes, hacks, workarounds, swallowed errors, hardcoded values, security shortcuts, timing hacks, copy-paste artifacts, and code smells in a codebase. Use when auditing code quality, reviewing tech debt, checking rapid fixes, investigating recurring bugs, or looking for hacky workarounds.'
argument-hint: 'scope, language, suspected files, recent incident/fix context, optional risk tolerance'
---

# Find Brute-Force Fixes and Code Smells

## Goal

Find implementation shortcuts that may work locally or temporarily but create reliability, portability, security, maintainability, or observability risk.

This skill is an audit workflow. It gathers evidence, filters false positives, classifies findings by impact, and recommends concrete next actions. Do not treat keyword hits as findings until the surrounding code has been reviewed.

> Apply the shared audit conventions in `.copilot/skills/_audit-conventions.md` (exclusions, "search broadly / judge narrowly", implementation-usefulness priority decisions using the Fix now / Plan first / Defer-accept grading vocabulary, and the report shape) before auditing. This priority grading is separate from severity, and the priority decision does not override severity.

## When to Use

Use this skill when the user asks to:

- Find brute-force fixes, hacks, workarounds, quick fixes, or code smells.
- Audit technical debt after an incident, migration, rushed change, or production hotfix.
- Review code for swallowed errors, hidden failures, hardcoded values, timing hacks, debug leftovers, or security shortcuts.
- Investigate why the same bug keeps recurring.
- Check whether code is production-ready before release or deployment.

## Procedure

1. Define scope and context.
   - Use the scope provided by the user. If no scope is provided, inspect the workspace structure and focus on source, scripts, infrastructure, config, and tests that are relevant to the request.
   - Identify languages and frameworks before choosing scan patterns.
   - If this audit follows a specific incident or fix, inspect the touched files and adjacent call paths first, then broaden the scan.

2. Run language-aware and text searches.
   - Prefer project-native lint, type, security, test, and static-analysis commands when they already exist.
   - Use language-aware references, diagnostics, or AST tools where practical for unreachable code, duplicate imports, and broad exception handling.
   - Use text search for marker comments, shell suppressions, hardcoded literals, and suspicious command flags.
   - For each hit, read enough surrounding code to classify intent and impact.

3. Scan marker comments.
   - Search for `HACK`, `FIXME`, `XXX`, `TODO` with risk wording, `WORKAROUND`, `TEMP`, `temporary`, `kludge`, `brute force`, `force fix`, `quick fix`, `band-aid`, `monkey patch`, `ugly`, `for now`, and `remove later`.
   - Do not report harmless documentation, test assertion strings, changelog text, generated code comments, or normal standard-library names such as temporary-file APIs.

4. Scan swallowed errors and hidden failures.
   - Look for bare catch/except blocks, catch-all handlers that return defaults, empty catch blocks, `except: pass`, `except Exception: pass`, `catch (...) {}`, promise `.catch(() => {})`, broad error suppression without logging, and single-line try/catch wrappers around risky operations.
   - In shell and CI scripts, inspect `|| true`, `2>/dev/null`, `>/dev/null 2>&1`, `set +e`, `continue-on-error`, ignored exit codes, and pipelines without error handling.
   - Accept intentional graceful degradation only when there is fallback behavior, useful logging, bounded scope, and a clear reason.

5. Scan hardcoded and environment-specific values.
   - Look for credentials, tokens, API keys, secrets, passwords, connection strings, private keys, hardcoded IPs, hostnames, tenant IDs, subscription IDs, account names, cloud resource names, ports, user-specific paths, absolute machine paths, region names, and opaque generated suffixes.
   - Distinguish named constants, documented defaults, test fixtures, examples, and local development templates from values embedded in production logic.
   - Flag overridable defaults when the default itself contains an environment-specific identifier that will be wrong in another workspace, tenant, region, account, or deployment.

6. Scan retry, sleep, and timing hacks.
   - Look for fixed sleeps, unbounded loops, polling without timeout, retries without backoff, magic retry counts, busy waits, race-condition comments, and time-based synchronization.
   - Treat bounded health checks, startup probes, integration-test waits, rate-limit handling, and documented eventual-consistency polling as acceptable when they have timeout, backoff, and useful diagnostics.

7. Scan security shortcuts and destructive bypasses.
   - Look for TLS verification disabled, authentication or authorization bypasses, permissive CORS, broad firewall rules, insecure cookie/session settings, unsafe deserialization, dynamic code execution, shell injection risk, overly permissive file modes, and destructive flags without confirmation.
   - Examples include `verify=False`, `--no-verify`, `NODE_TLS_REJECT_UNAUTHORIZED=0`, `rejectUnauthorized: false`, `curl -k`, `chmod 777`, `eval`, `exec`, `shell=True`, `pickle.loads` on untrusted input, `allow_origins=["*"]`, `--force`, and recursive deletes.
   - Evaluate context carefully: test fixtures and isolated local tooling are lower risk than production code, infrastructure, auth, deployment, or CI paths.

8. Scan copy-paste and rushed-change artifacts.
   - Look for large commented-out code blocks, duplicate imports, unused variables introduced by refactors, debug prints/logs, console statements, breakpoint statements, debugger hooks, unreachable code after terminators, duplicated conditions, stale comments that contradict code, and repeated blocks with small manual edits.
   - Exclude intentional CLI output, examples, tutorials, test assertions, migration notes, and embedded scripts where printing is the expected behavior.

9. Classify each reviewed item.

| Severity | Criteria |
| --- | --- |
| Critical | Security bypass, hardcoded credential, destructive unsafe behavior, or swallowed failure that can hide data loss/security/production outage. |
| High | Portability-breaking hardcoded environment values, timing hacks likely masking races, broad error suppression in important runtime paths, or risky deployment/infra shortcuts. |
| Medium | Marker comments that identify known debt, debug leftovers in production paths, commented-out code, unbounded loops with limited blast radius, or maintainability smells likely to cause future defects. |
| Low | Overridable but imperfect defaults, bounded retry/polling, intentional suppression with fallback, or low-risk cleanup opportunities. |
| Accept | Pattern is intentional, documented, test-only, generated, local-only, or otherwise correct in context. |

10. Recommend a fix strategy.

| Strategy | Use When |
| --- | --- |
| Extract to config | Environment-specific literals should become configuration, parameters, secrets, or deployment outputs. |
| Add error handling | Suppressed errors need logging, context, fallback, retry, or propagation. |
| Add backoff and timeout | Sleep/retry loops need bounded retries, exponential backoff, deadlines, or circuit breakers. |
| Fix root cause | Timing hacks or repeated retries are hiding synchronization, dependency, lifecycle, or consistency problems. |
| Remove dead artifact | Commented-out blocks, duplicate imports, debug statements, and unreachable leftovers have no current purpose. |
| Harden security | Security shortcuts need safe defaults, validation, least privilege, confirmation, or secure APIs. |
| Document intentional behavior | Suspicious-looking code is correct but needs a short explanation to prevent churn. |
| Accept no action | Fixing would add complexity without reducing meaningful risk. |

11. Search for existing helpers before proposing code changes.
   - Before recommending new utilities, search the codebase for existing helpers, wrappers, config loaders, retry utilities, logging conventions, secret accessors, deployment-output readers, and platform abstractions.
   - Prefer reusing local conventions over inventing parallel mechanisms.

12. Report results.
   - Lead with confirmed actionable findings, ordered by severity.
   - Include accepted patterns only after actionable findings, so the user can see suspicious hits were reviewed.
   - Include exact file references, short snippets when useful, impact, recommendation, and verification steps.
   - If no actionable findings are found, say that clearly and mention scan limits.

## Common Search Seeds

Adapt these to the project language and scope:

- Marker comments: `HACK|FIXME|XXX|WORKAROUND|TEMP|temporary|kludge|brute.?force|force.?fix|quick.?fix|band.?aid|monkey.?patch|remove later|for now`
- Swallowed errors: `except:|except Exception|catch \(|catch\s*\([^)]*\)\s*\{\s*\}|\.catch\(\s*\(.*\)\s*=>\s*\{?\s*\}?\s*\)|pass\s*$|\|\| true|2>/dev/null|continue-on-error|set \+e`
- Hardcoded sensitive values: `password\s*=|passwd\s*=|api[_-]?key\s*=|secret\s*=|token\s*=|connection[_-]?string\s*=|BEGIN .*PRIVATE KEY`
- Environment-specific values: IPv4 addresses, absolute paths, cloud account IDs, resource names with generated suffixes, tenant/subscription/project identifiers, and non-local hostnames.
- Timing hacks: `sleep\(|time\.sleep|Thread\.sleep|setTimeout|setInterval|while True|for \(;;\)|retry|backoff|poll`
- Security shortcuts: `verify=False|--no-verify|rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*0|curl .* -k|chmod 777|chmod 666|shell=True|eval\(|exec\(|allow_origins\s*=\s*\[\s*["']\*["']`
- Debug leftovers: `print\(|console\.log|debugger;|breakpoint\(|pdb\.set_trace|TODO.*remove|commented out`

## Completion Criteria

The audit is complete when suspicious hits have been reviewed in context, actionable findings are classified by severity, accepted patterns include rationale, recommendations reuse existing project conventions where possible, and verification steps are specific enough for the user to act on.
