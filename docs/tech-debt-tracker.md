# Tech Debt Tracker

Knowingly-deferred Minor/Low (or human-agreed Medium) findings from the Pre-PR
verify gate. Each row names the finding, its origin, severity, and a clearing
condition. Fix opportunistically; do not let rows rot.

| ID | Origin | Severity | Finding | Clearing condition |
|----|--------|----------|---------|--------------------|
| TD-001 | #243 code-review (verify gate) | Minor | `scripts/start-issue.sh`: the best-effort hook-liveness warn is emitted just before the "refuse to run from a linked worktree" hard-fail, so a mis-invocation from a worktree prints an advisory warn immediately before the error. Purely cosmetic (both go to stderr; exit codes unchanged). | When start-issue.sh is next edited in that region, reorder so the worktree-refuse check precedes the advisory warn. |
