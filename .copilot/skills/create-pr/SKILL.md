---
name: create-pr
description: Create well-structured pull requests with meaningful titles, descriptions, and proper branch management.
---

# Create Pull Request

This skill enables the agent to create complete, well-structured pull requests following best practices for branch naming, commit organization, and PR descriptions.

## Workflow

1. **Create a feature branch** — Use a descriptive branch name following the convention `<type>/<short-description>` (e.g., `feat/add-user-auth`, `fix/null-pointer-login`, `docs/update-readme`).

2. **Stage and commit changes** — Group related changes into atomic commits with clear messages following Conventional Commits format:
   ```
   <type>(<scope>): <short summary>

   <optional body explaining what and why>
   ```
   Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`

3. **Pre-PR Quality Gates** — Before pushing, run through these checks using the companion skills:

   - **Code Review** (`skills/code-review`) — Self-review all changed files for bugs, logic errors, readability, and DRY violations. Fix any Critical or Warning issues before proceeding.
   - **Language Conventions** (`skills/typescript`, `skills/python`, etc.) — Verify the code follows the project's language-specific patterns, naming conventions, and architecture standards.
   - **Security Audit** (`skills/security-audit`) — Scan changes for injection vulnerabilities, hardcoded secrets, missing auth checks, and insecure dependencies. No Critical findings allowed.
   - **Testing** (`skills/testing`) — Ensure new logic has corresponding tests. Run the test suite and confirm all tests pass with adequate coverage on changed code.

4. **Push the branch** — Push to the remote repository only after all quality gates pass.

5. **Create the pull request** — Use `gh pr create` with:
   - A clear, concise title summarizing the change
   - A structured description body (include quality gate results)
   - Appropriate labels, reviewers, and milestone (if applicable)

## PR Description Template

```markdown
## Summary
Brief description of what this PR does and why.

## Changes
- Bullet list of key changes made

## Quality Checks
- [x] Code review: no critical/warning issues
- [x] Language conventions: follows project standards
- [x] Security: no vulnerabilities found
- [x] Tests: all passing, new tests added for new logic

## Testing
- How the changes were tested
- Any new tests added

## Related Issues
Closes #<issue-number>
```

## Commands

```bash
# Create branch
git checkout -b feat/my-feature

# Stage and commit
git add -A
git commit -m "feat(scope): description"

# Push and create PR
git push -u origin feat/my-feature
gh pr create --title "feat(scope): description" --body "..." --label "enhancement"
```

## Best Practices

- **One concern per PR** — Keep PRs focused on a single feature or fix. Split large changes into smaller, reviewable PRs.
- **Keep PRs small** — Aim for under 400 lines changed. Large PRs get superficial reviews.
- **Link related issues** — Use `Closes #123` or `Fixes #456` to auto-close issues on merge.
- **Add context for reviewers** — Explain the "why" not just the "what." Include screenshots for UI changes.
- **Request specific reviewers** — Choose people familiar with the area of code being changed.
- **Use draft PRs** — Mark as draft if the work is in progress and not ready for review.
- **Rebase before creating** — Ensure your branch is up to date with the base branch to avoid merge conflicts.

## Edge Cases

- **Empty repos** — Ensure at least one commit exists on the base branch before creating a PR.
- **Fork workflows** — Use `gh pr create --head user:branch` when working from a fork.
- **Multiple remotes** — Specify the correct remote with `--repo owner/repo` if ambiguous.
- **CI requirements** — Some repos require passing checks before merge; note this in the PR description if tests are still running.
