---
name: security-audit
description: 'Repo-scoped security audit for this harness/docs/scripts project — shell and CI script injection, GitHub Actions workflow permissions, dependency pinning, and secrets handling. Use for issues touching auth, CI/workflows, provisioning, or data movement.'
argument-hint: 'scope (paths), changed area, remote/push status, optional already-installed scanners'
---

# Security Audit

Audit this repository's real attack surface: shell scripts, CI workflows, dependency manifests, and secret handling.
This is a harness/docs/scripts repo, not a deployed web app — do not assume a running server, cloud account, or
three-tier app. For accidental exposure of secrets/PII/identifiers in tracked files or Git history, use the
`public-exposure-audit` skill; this skill covers exploitable defects in the scripts and pipelines themselves.

**Built-in tools first.** Use `git`, `grep`/`rg`, and reading the code to reach a verdict. Scanners
(`shellcheck`, `gitleaks`, `actionlint`, `trivy`, dependency audits) are optional accelerators — use them only if
already available; never make a finding contingent on a tool the repo doesn't install.

## What to check

- **Shell / CI script injection** — untrusted input (GitHub event fields, `${{ github.* }}`, env, args, file
  contents) reaching `eval`, `bash -c`, unquoted expansions, `curl | sh`, or command substitution. Flag missing
  quoting and word-splitting that lets input become code.
- **Workflow permissions** — over-broad `permissions:` (default or `write-all`), `pull_request_target` with checkout
  of untrusted head + secret access, unpinned third-party actions (use a commit SHA, not a floating tag), and secrets
  exposed to fork PRs.
- **Dependency pinning** — unpinned or range-pinned dependencies in manifests/lockfiles for anything that runs in CI
  or provisioning; prefer exact versions / lockfiles / SHA-pinned actions.
- **Secrets handling** — hardcoded tokens/keys, secrets echoed to logs or passed on the command line, credentials
  read from anything other than env/secret store, and secrets written to tracked files.

## Report

For each finding give **severity** (Critical / High / Medium / Low / Info), **evidence** (file + line + the exact
sink), **exploit path** (how untrusted input reaches it), and a **concrete remediation**. Close with a one-line
severity count. Severity reflects exploitability and blast radius, not tool output volume; if you could not verify
something (e.g. no scanner available), say so explicitly rather than implying coverage.
