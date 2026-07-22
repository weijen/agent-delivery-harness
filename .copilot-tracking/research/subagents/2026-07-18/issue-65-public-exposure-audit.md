---
title: Issue 65 public exposure audit
description: Report-only public exposure audit evidence for the issue 65 branch
---

## Research scope

* Audit issue #65 changed and tracked content before public push and PR creation
* Inspect branch commits and Git metadata
* Inspect relevant reachable-history residuals separately from newly introduced exposure
* Inspect ignored and untracked local files, including `.copilot-tracking/research/`, without exposing secret values
* Establish remote and pushed status
* Classify candidates as Exposure or Accept with severity, pushed status, and remediation priority

## Findings

| Verdict | Severity | Candidate | Pushed status | Classification and remediation |
|---------|----------|-----------|---------------|--------------------------------|
| Accept | Accept | Issue #65 changed content | Two implementation commits are pushed to the public feature branch; the documentation commit is local-only | No token prefix, private-key marker, cloud GUID, absolute home path, email address, credential label, private endpoint, customer media, or export was found in added lines. Defer-accept. |
| Accept | Accept | Untracked `.copilot-tracking/research/` reports | Local-only, untracked, and not staged | Seven Markdown reports were inspected. Count-only scans found no token prefix, private-key marker, cloud GUID, absolute home path, email address, or credential label. Keep untracked. Defer-accept. |
| Accept | Accept | Untracked `.vscode/tasks.json` | Local-only, untracked, and not staged | A late editor-created task file was inspected. Count-only scans found no token prefix, private-key marker, cloud GUID, absolute home path, or email address. Defer-accept. |
| Accept | Accept | Unstaged `uv.lock` change | Local-only and unstaged | One line changed in each direction. No token prefix, cloud GUID, or absolute home path was found. It is unrelated worktree residue, not exposure. Defer-accept. |
| Accept | Accept | Ignored local surface | Local-only | No ignored filenames indicated credentials, tokens, keys, exports, dumps, or backups. No real `.env` file exists. `.venv` and tool caches are excluded generated surfaces. Defer-accept. |
| Exposure | High | Personal email in reachable Git metadata | Already pushed to the public repository | One Gmail address appears in author or committer metadata across 143 reachable commits. This predates issue #65. Plan first: use GitHub noreply for future commits, consider `.mailmap`, and make any optional coordinated history rewrite an owner decision. Do not auto-fix history. |
| Accept | Accept | Historical secret-shape matches | Already pushed | Matches occur in redaction tests and trace sanitization fixtures. They are synthetic regression inputs, not live credentials. Defer-accept. |
| Accept | Accept | Historical cloud GUID match | Already pushed | The GUID is a Terraform workbook resource name. Its Azure source ID is dynamically resolved, and no tenant ID, subscription ID, embedded private endpoint, or credential is present. Defer-accept. |
| Accept | Accept | Historical absolute-path matches | Already pushed | Matches occur in the public-exposure audit examples, sanitization tests, and synthetic trace fixture documentation. Defer-accept. |
| Accept | Accept | Tags, notes, and refs | Already pushed where remote refs exist | Tags are release tags plus the documented semantic-release anchor. No Git notes exist. No sensitive tag or note metadata was found. Defer-accept. |

## Remote status

* Repository `weijen/agent-delivery-harness` is public
* Public feature branch points to commit `dbb6b350642375b129e5878306664e4177fe7de4`
* Local issue head is `931eb93459f5c51f5937fbf4ffdcde12f46e4ecc`, one commit ahead of the public feature branch
* No pull request exists for the issue branch at audit time
* The issue branch is three commits ahead of its `origin/main` merge base and has no `origin/main`-only commits

## Scope completion

* Changed and tracked issue content: complete
* Current tracked tree: complete with built-in Git pattern checks
* Branch commits and metadata: complete
* Local and remote branch tips, tags, and notes: complete
* Relevant reachable-history residuals: complete using history-diff candidate searches and contextual classification
* Ignored and untracked local files: complete for the issue worktree, including the late-created `.vscode/tasks.json`
* Optional scanners: `gitleaks`, `trufflehog`, and `detect-secrets` were not installed; no installation was required

## Decision

Issue #65 introduces no confirmed public exposure. The public feature branch is safe, and the local documentation commit is safe to push and open as a public pull request. The personal-email metadata finding is already-published residual exposure unrelated to issue #65 and does not change the issue-specific go decision.

`PUBLIC_EXPOSURE_AUDIT: PASS`

## References and evidence

* Audit protocol: `.copilot/skills/public-exposure-audit/SKILL.md`
* Shared grading: `.copilot/skills/_audit-conventions.md`
* Issue comparison base: `2bced33d3188481e361190e5dae0787a6ee6de31`
* Changed files: `.github/workflows/harness-smoke.yml`, `docs/PROGRESS.md`, `tests/evals/bin/validate-customization-frontmatter.sh`, `tests/scripts/test_customization_frontmatter_validator.sh`, `tests/scripts/test_customization_frontmatter_wiring.sh`, and `tests/scripts/test_harness_smoke.sh`
* Staging proof: `git diff --cached --name-status` returned no paths; `git ls-files --stage -- .copilot-tracking/research` returned no entries; `git status --porcelain=v1 --untracked-files=all -- .copilot-tracking/research` listed all seven reports with `??`
* History metadata domains: `users.noreply.github.com`, `github.com`, and `gmail.com`; local parts were suppressed during reporting
* Candidate scans emitted counts and paths only; token-like or secret values were not printed

## Clarifying questions

None.
