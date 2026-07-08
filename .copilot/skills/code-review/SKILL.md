---
name: code-review
description: Perform thorough code reviews on files or pull requests, checking for bugs, security vulnerabilities, performance issues, and style violations.
argument-hint: 'files or diff to review, change intent, optional severity focus'
---

# Code Review

Review a file, a set of changes, or a pull request across correctness, security, performance, readability, and
maintainability, and report actionable findings tied to specific lines.

## Workflow

1. **Establish context.** Detect whether the input is a file, a directory, or a PR diff. For a PR, fetch the diff and
   base branch so only changed lines are reviewed. Read linter/style/type configs to calibrate to the project.
2. **Understand the intent first.** Read commit messages, the PR description, and surrounding code so you judge the
   code against its goal, not your assumptions — this prevents false positives. Summarize the change in one sentence
   before judging it.
3. **Correctness and bugs.** Trace data flow through each changed function: null/undefined derefs, off-by-one, wrong
   boolean logic, unhandled error paths, concurrency races, resource leaks, and unhandled edge cases (empty, max,
   unexpected types).
4. **Security.** Unsanitized input (injection, XSS), hardcoded secrets, insecure crypto, over-permissive file/network
   access, missing authn/authz, and risky dependency additions.
5. **Performance and scalability.** Algorithmic blowups (nested loops, N+1 queries, unbounded growth), needless
   allocations, missing caching, and blocking calls in async contexts — judged against expected data volume.
6. **Readability and maintainability.** Naming, function length, duplication (DRY), style-guide adherence, docs/type
   annotations on public surfaces, named constants over magic numbers.

## Review Checklist

| Category        | What to look for                                                        |
|-----------------|-------------------------------------------------------------------------|
| Bugs            | Null derefs, off-by-one, logic errors, unhandled exceptions             |
| Security        | Injection, XSS, hardcoded secrets, missing auth, insecure dependencies  |
| Performance     | O(n²) loops, N+1 queries, unnecessary allocations, blocking I/O        |
| Readability     | Unclear names, long functions, missing docs, inconsistent formatting    |
| DRY             | Copy-pasted blocks, duplicated logic that should be extracted           |
| Error handling  | Swallowed exceptions, missing retries, unclear error messages           |
| Testing         | Missing tests for new logic, broken existing tests, untested edge cases |

## Report

Classify each finding **Critical / Warning / Info** and close with a one-line count summary
(e.g. `2 critical, 1 warning`). Tie every finding to a line and give a concrete fix, not a vague complaint.

## Best Practices

- **Review the diff, not the file** — focus on changed lines and their immediate context; skip pre-existing issues
  unless the change interacts with them.
- **Limit scope per round** — prioritize the top 5–7 most impactful findings; overwhelming the author reduces the
  chance anything gets fixed.
- **Acknowledge good patterns** — call out a clean abstraction or a well-handled edge case.
- **Check tests alongside code** — flag missing tests; verify existing tests exercise the changed behavior, not just
  the happy path.

## Edge Cases

- **Generated/vendored code** — skip files matching common generated-code patterns unless explicitly asked.
- **Large diffs (>1000 lines)** — warn and suggest splitting; focus on the highest-risk files first.
- **Language idioms** — adjust expectations to the detected language (e.g. Go's explicit error returns).
- **Incomplete context** — when the full repo isn't available, state assumptions about types/config/callers explicitly.
- **Style-only changes** — confirm no semantic difference and give a short approval, not a full report.
