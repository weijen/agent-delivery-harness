---
name: create-pr
description: Open a pull request that follows this repository's issue-driven harness conventions — branch naming, issue-scoped Conventional Commits, HEAD-bound review, and the CI-green squash-merge discipline.
argument-hint: 'issue number, change summary, base branch, optional fork/remote'
---

# Create Pull Request

Open a PR the way this repo actually works: one issue per branch, gates recorded before the push, and a
CI-green merge through the harness scripts. Prefer the scripts (`scripts/start-issue.sh`, `scripts/create-pr.sh`,
`scripts/merge-pr.sh`) over hand-run `git`/`gh` — they encode the rules below as actions.

## Workflow

1. **Branch** — one branch per issue, named `feature/issue-<NN>-<slug>` (e.g. `feature/issue-181-codify-create-pr`).
   `scripts/start-issue.sh <NN>` creates it (plus the isolated worktree) off `main`.
2. **Commit** — Conventional Commits. Scope with the driving **issue number** when a single issue owns the change
   (`feat(#181): …`, `fix(#177): …`); use a **component** scope otherwise (`feat(trace): …`, `docs(ci-gate): …`).
   Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`. Keep the subject ≤ ~72 chars; put detail in the body.
   Keep commit signing on, and end the message with the repo's `Co-authored-by: Copilot …` trailer.
3. **Pre-PR gates** — before pushing, run the companion skills that exist here and record the HEAD review:
   - **`code-review`** — self-review the diff; fix Critical/Warning findings first.
   - **`security-audit`** — scan the diff for injection, secrets, workflow-permission and pinning gaps.
   - **`scripts/review-gate.sh approve`** — records the current HEAD as reviewed (the PR path requires it).
   Stage only the files you intend to publish (respect public-exposure hygiene); never blanket-stage with `git add -A`.
4. **Open the PR** — `scripts/create-pr.sh --title "…" --body "…"` re-syncs onto latest `main`, re-checks the review
   approval, pushes, and opens the PR. Use the template below and link the issue with `Closes #<NN>`.
5. **Merge** — only after the `Harness smoke` CI run is green. `scripts/merge-pr.sh --squash` verifies `gh pr checks`
   is green, then squash-merges (the PR number is appended to the subject automatically). A green CI run is a hard
   precondition; do **not** enable GitHub auto-merge as a standing practice.

## PR Description Template

```markdown
## Summary
Brief description of what this PR does and why.

## Changes
- Bullet list of key changes made

## Quality Checks
- [x] Code review: no critical/warning issues
- [x] Security: no findings

## Testing
- How the changes were verified (name the sensor(s) run)

## Related Issues
Closes #<NN>
```

## Edge Cases

- **Fork workflows** — `gh pr create --head user:branch`.
- **Multiple remotes** — disambiguate with `gh pr create --repo owner/repo`.
- **`merge-pr.sh` resolves the PR from the current worktree branch** — run it from the issue's worktree and pass only
  flags (no PR number).
