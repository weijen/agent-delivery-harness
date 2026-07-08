---
name: create-pr
description: Create well-structured pull requests with meaningful titles, descriptions, and proper branch management.
argument-hint: 'issue number, change summary, base branch, optional fork/remote'
---

# Create Pull Request

## Workflow

1. **Branch** — name it `<type>/<short-description>` (e.g. `feat/add-user-auth`, `fix/null-pointer-login`,
   `docs/update-readme`).
2. **Commit** — group related changes into atomic commits in Conventional Commits format
   (`<type>(<scope>): <summary>` with an optional body). Types: `feat`, `fix`, `docs`, `style`, `refactor`,
   `test`, `chore`.
3. **Pre-PR quality gates** — before pushing, run the companion skills that exist in this repo:
   - **`code-review`** — self-review the diff for bugs, logic errors, and DRY violations; fix Critical/Warning
     findings first.
   - **`security-audit`** — scan the diff for injection, secrets, missing auth, and insecure dependencies; no
     Critical findings.
   Stage only the files you intend to publish (respect this repo's public-exposure hygiene); never blanket-stage.
4. **Push** the branch only after the gates pass.
5. **Open the PR** with a clear title, the description template below (include gate results), and a `Closes #<n>`
   link to the issue.

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
- How the changes were tested

## Related Issues
Closes #<issue-number>
```

## Edge Cases

- **Fork workflows** — create the PR with `gh pr create --head user:branch`.
- **Multiple remotes** — disambiguate with `gh pr create --repo owner/repo`.
