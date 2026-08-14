---
mode: agent
description: 'Run the six-skill local audit sweep and summarize the Fix-now findings.'
---

# Audit Sweep

Run the repository audit sweep and report the results.

Scope (optional subset of audit skills, space-separated; empty = all six):
**${input:scope:audit skills to run, e.g. "find-duplicates security-audit" — leave blank for all six}**

Steps:

1. Run the driver from the repo root: `./scripts/audit-sweep.sh ${input:scope}`.
   It launches each audit skill in its own fresh, report-only `copilot -p`
   session and writes one report per skill under `logs/audit/<UTC-timestamp>/`.
   Do not run the audits yourself in this session — the script owns that so each
   audit gets a fresh context.
2. When the sweep finishes, read the consolidated `index.md` it prints the path
   to (`logs/audit/<UTC-timestamp>/index.md`).
3. Summarize back to the user: the **Fix-now** findings from the roll-up table
   first (skill, severity, file), then a one-line count of Plan-first /
   Defer-accept items. Link the `index.md` path for the full detail.

Notes:

- The sweep is **report-only**; it never modifies files. `sync-docs` runs in
  report mode here — run its fix mode separately by hand.
- `logs/audit/` is gitignored: the reports are local artifacts, never committed.
- If the script exits non-zero, a skill failed to complete; name which one and
  point the user at its report under the timestamped directory.
