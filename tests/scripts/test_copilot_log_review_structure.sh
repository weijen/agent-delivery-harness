#!/usr/bin/env bash
# test_copilot_log_review_structure.sh — regression sensor for issue #306,
# feature log-review-structure: the copilot-log-review SKILL.md ships the
# remaining Locate / Qualify / Report stages plus the report-only + privacy and
# per-OS-path conventions, so the report-only skill is complete.
#
# Contract under test (PINNED HERE as the executable spec). The SKILL.md must
# carry, in dedicated sections (so a revert of this feature's edit fails the
# sensor — the assertions are scoped to the new sections, NOT to the pre-existing
# frontmatter / Quantify prose that already mentions "report-only",
# "reasoningText", and the logs/audit path):
#
#   Locate stage  — resolve the workspace hash (workspaceStorage/*/workspace.json),
#                   enumerate sessions overlapping the review window OR an issue's
#                   lifecycle-span window read from
#                   .copilot-tracking/issues/issue-NN/trace.jsonl (the offline,
#                   time-window join), and the verified macOS transcript path
#                   (…/Code/User/workspaceStorage/<hash>/GitHub.copilot-chat/
#                   transcripts/<sessionId>.jsonl). Per-OS: only macOS verified;
#                   Windows (%APPDATA%) and Linux (~/.config) variants unverified.
#   Qualify stage — sample `reasoningText` around key decisions.
#   Report stage  — follow `_audit-conventions.md`, write to
#                   logs/audit/<UTC-timestamp>/copilot-log-review.md, and compare
#                   against the previous report (trend, not snapshot).
#   Report-only + privacy — never edits the repo; transcripts hold full content,
#                   so quote sparingly, route quotes through the redaction
#                   patterns, and NEVER commit raw transcript excerpts.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the SKILL.md still carries only frontmatter + Quantify).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="${ROOT}/.copilot/skills/copilot-log-review/SKILL.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${SKILL}" ]; then
  printf 'FAIL: SKILL.md not found (%s)\n' "${SKILL}" >&2
  exit 1
fi

# section <heading-ERE> <file>
# Prints from the first line matching <heading-ERE> down to (but excluding) the
# next top-level `## ` heading. Scoping each stage's assertions to its own
# section is what gives this sensor teeth: reverting the feature deletes the
# section, and the pre-existing frontmatter / Quantify text cannot mask it.
section() {
  awk -v hre="$1" '
    /^## / { if (inb) exit }
    $0 ~ hre { inb = 1 }
    inb { print }
  ' "$2"
}

# flatten <text> — join to one spaced line so phrase assertions tolerate the
# markdown hard line-wraps in prose.
flatten() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

# --- Locate stage -----------------------------------------------------------
if ! grep -qE '^## Locate[[:space:]]*$' "${SKILL}"; then
  fail "Locate: missing a '## Locate' stage heading"
fi
loc="$(flatten "$(section '^## Locate[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${loc}" | grep -qiF 'workspace.json' \
  || fail "Locate: must resolve the workspace hash via workspaceStorage/*/workspace.json"
printf '%s\n' "${loc}" | grep -qF 'workspaceStorage' \
  || fail "Locate: must name the workspaceStorage directory"
printf '%s\n' "${loc}" | grep -qiF 'review window' \
  || fail "Locate: must enumerate sessions overlapping the review window"
printf '%s\n' "${loc}" | grep -qiF 'lifecycle-span' \
  || fail "Locate: must support an issue lifecycle-span enumeration window"
printf '%s\n' "${loc}" | grep -qF 'trace.jsonl' \
  || fail "Locate: lifecycle-span window must come from .copilot-tracking/issues/issue-NN/trace.jsonl"
printf '%s\n' "${loc}" | grep -qiF 'offline join' \
  || fail "Locate: must describe the offline (time-window) session-to-issue join"

# Verified macOS transcript path fragments.
printf '%s\n' "${loc}" | grep -qF 'Library/Application Support/Code/User/workspaceStorage' \
  || fail "Locate: must give the verified macOS workspaceStorage path"
printf '%s\n' "${loc}" | grep -qF 'GitHub.copilot-chat/transcripts' \
  || fail "Locate: must give the verified macOS transcript path (GitHub.copilot-chat/transcripts)"

# Per-OS: macOS verified, Windows + Linux variants unverified.
printf '%s\n' "${loc}" | grep -qiF 'only macOS paths are verified' \
  || fail "Locate: must state only macOS paths are verified"
printf '%s\n' "${loc}" | grep -qF '%APPDATA%' \
  || fail "Locate: must give the Windows (%APPDATA%) workspaceStorage variant"
printf '%s\n' "${loc}" | grep -qF '.config/Code/User/workspaceStorage' \
  || fail "Locate: must give the Linux (~/.config) workspaceStorage variant"
printf '%s\n' "${loc}" | grep -qiF 'unverified' \
  || fail "Locate: must mark the Windows/Linux variants as unverified"

# --- Qualify stage ----------------------------------------------------------
if ! grep -qE '^## Qualify[[:space:]]*$' "${SKILL}"; then
  fail "Qualify: missing a '## Qualify' stage heading"
fi
qual="$(flatten "$(section '^## Qualify[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${qual}" | grep -qF 'reasoningText' \
  || fail "Qualify: must sample reasoningText around key decisions"

# --- Report stage -----------------------------------------------------------
if ! grep -qE '^## Report[[:space:]]*$' "${SKILL}"; then
  fail "Report: missing a '## Report' stage heading"
fi
rep="$(flatten "$(section '^## Report[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${rep}" | grep -qF '_audit-conventions.md' \
  || fail "Report: must follow the shared _audit-conventions.md report shape"
printf '%s\n' "${rep}" | grep -qF 'logs/audit/' \
  || fail "Report: must name the logs/audit/<UTC-timestamp>/ output directory"
printf '%s\n' "${rep}" | grep -qF 'copilot-log-review.md' \
  || fail "Report: must write to logs/audit/<UTC-timestamp>/copilot-log-review.md"
printf '%s\n' "${rep}" | grep -qiF 'previous report' \
  || fail "Report: must compare against the previous report when one exists"
printf '%s\n' "${rep}" | grep -qiF 'trend' \
  || fail "Report: must produce a trend, not a snapshot"

# --- Report-only + privacy --------------------------------------------------
if ! grep -qE '^## Report-only and privacy[[:space:]]*$' "${SKILL}"; then
  fail "Privacy: missing a '## Report-only and privacy' section"
fi
priv="$(flatten "$(section '^## Report-only and privacy[[:space:]]*$' "${SKILL}")")"

printf '%s\n' "${priv}" | grep -qiF 'report-only' \
  || fail "Privacy: must restate the skill is report-only"
printf '%s\n' "${priv}" | grep -qiF 'never edit' \
  || fail "Privacy: must state the skill never edits the repo"
printf '%s\n' "${priv}" | grep -qiF 'never commit' \
  || fail "Privacy: must forbid committing raw transcript excerpts (never commit)"
printf '%s\n' "${priv}" | grep -qiF 'transcript' \
  || fail "Privacy: must scope the never-commit rule to transcript content"
printf '%s\n' "${priv}" | grep -qiF 'redact' \
  || fail "Privacy: must route quotes through the redaction patterns"

if [ "${fails}" -ne 0 ]; then
  printf '\n%d copilot-log-review structure obligation(s) failed.\n' "${fails}" >&2
  exit 1
fi

printf 'PASS: copilot-log-review SKILL.md ships Locate/Qualify/Report stages, report-only + privacy, and per-OS paths.\n'
