---
agent: agent
description: 'Run the local audit driver and report actionable findings and incomplete audits.'
---

# Audit Sweep

Run a report-only audit in the harness source checkout. The driver is not installed
in adopter projects; if it is absent, report that limitation rather than recreating it.

Scope (space-separated audit skill names; blank selects all discovered audits):
**${input:scope:Optional audit skills, e.g. find-duplicates sync-docs}**

Steps:

1. Treat scope as skill names, not shell syntax or flags. From the repository root,
   run `./scripts/maintenance/audit-sweep.sh --dry-run` with those names as separate
   arguments. On invalid input or a missing prerequisite, report the error and stop.
2. Run the same selection without `--dry-run`. The driver owns the fresh,
   report-only audit sessions; do not run additional audits or remediate findings.
   This also overrides `sync-docs`' usual edit mode.
3. Read the printed `index.md` and report: incomplete audits first, then confirmed
   **Fix now** findings (skill, severity, file), counts of **Plan first** /
   **Defer-accept** findings, and the index path. Distinguish partial findings from
   a completed clean audit. Exit 1 means a child audit failed; name it and link its
   report. Other failures may be usage or setup errors, with no report available.

The driver writes gitignored local reports under `logs/audit/<UTC-timestamp>/`
(or `AUDIT_LOG_ROOT` when set); source edits and committing reports are out of scope.
