# Tech Debt Tracker

Knowingly-deferred Minor/Low (or human-agreed Medium) findings from the Pre-PR
verify gate. Each row names the finding, its origin, severity, and a clearing
condition. Fix opportunistically; do not let rows rot.

This is project-owned state, created on first need. The harness installer does
not distribute this repository's findings or overwrite an adopter's tracker.

## Active

No active findings are currently recorded.

## Resolved

| ID | Origin | Severity | Finding | Clearing condition |
|----|--------|----------|---------|--------------------|
| TD-001 | #243 code-review (verify gate) | Minor | The former hook-liveness warning preceded linked-worktree refusal in `scripts/start-issue.sh`. | Resolved by hook retirement (#305); the warning mechanism no longer exists. Reconciled 2026-09-19 in #468, not by restoring or reordering the retired hook. |
