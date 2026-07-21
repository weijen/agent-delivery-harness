#!/usr/bin/env bash
# test_subagent_permission_setup.sh — regression sensor for issue #319
# feature subagent-permission-setup.
#
# Contract under test: docs/getting-started.md must contain a discoverable
# section explaining the subagent permission model with three clearly separated
# layers:
#   1. Documented CLI tool-level session approval (approve the minimum tool;
#      approval applies with any options for that running session).
#   2. Environment/organization-specific exact-command allowlisting (must be
#      verified in the user's UI/policy; no guessed config syntax).
#   3. Explicit /autopilot handoff before spawning subagents (observed
#      operational authorization, not a guaranteed bypass).
#
# Additional obligations:
#   - Version-pin the observed permission-denial-storm symptom to CLI 1.0.72-1
#     (issue #319 observation, not universalized).
#   - Name scripts/log-handback.sh and scripts/review-gate.sh as *examples* of
#     exact entrypoints an environment-specific allowlist MAY scope.
#   - Warn about blanket /allow-all as an anti-pattern while acknowledging it
#     exists for trusted situations per official docs.
#   - Provide provenance labels (documented/observed/environment-specific) and
#     cite official GitHub Docs URL.
#   - NEVER claim /autopilot "grants blanket execution authority", "eliminates
#     prompts", or that the layers provide "sufficient coverage".
#
# Sensor legs (16 total):
#   A: A heading containing "permission" exists in docs/getting-started.md
#   B: The section names scripts/log-handback.sh and scripts/review-gate.sh as
#      example entrypoints (not as a "complete set")
#   C: The section names "/autopilot" (slash-command) as an alternative path
#   D: NEGATIVE — reject recommendation language for blanket allow-all; it must
#      be labeled as an anti-pattern
#   E: Symptom warning about "denial storm" or "permission storm" +
#      anti-pattern label
#   F: Version pin — the section references CLI version "1.0.72-1"
#   G: Tool-level session approval caveat — mentions approval applying with
#      "any options" or "any arguments" for that session
#   H: NEGATIVE — must NOT contain "allowed-commands list" (unsupported claim)
#   I: NEGATIVE — must NOT contain "complete set" (overclaim)
#   J: NEGATIVE — must NOT list scripts/trace-lib.sh as a direct command target
#   K: The section must reference /autopilot as a code-formatted slash-command
#   L: NEGATIVE — must NOT claim /autopilot "grants ... blanket execution
#      authority" (unsupported guarantee)
#   M: NEGATIVE — must NOT claim anything "eliminates ... prompts" as guarantee
#   N: NEGATIVE — must NOT claim "sufficient coverage" or equivalent guarantee
#   O: Provenance labels — must contain "(Documented)" and "(Observed" markers
#   P: Official citation — must cite the GitHub Docs URL for Copilot CLI
#
# Teeth: legs D, H, I, J, L, M, N are negative/safety checks — the sensor will
# fail if overclaiming language reappears.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/getting-started.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$DOC" ] || { fail "docs/getting-started.md not found"; exit 1; }

# --- Leg A: Heading containing "permission" (case-insensitive) ----------------
if ! grep -qiE '^#{1,4}[[:space:]].*[Pp]ermission' "$DOC"; then
  fail "Leg A: docs/getting-started.md must contain a heading with 'permission' (subagent permission section)"
fi

# --- Extract the permission section for scoped checks -------------------------
SECTION="$(sed -n '/^##[[:space:]].*[Pp]ermission/,/^##[[:space:]]/{
  /^##[[:space:]].*[Pp]ermission/p
  /^##[[:space:]]/!p
}' "$DOC")"

if [ -z "$SECTION" ]; then
  fail "Leg A (extraction): could not extract the permission section"
  SECTION=""
fi

# --- Leg B: Example entrypoints (not "complete set") --------------------------
script_count=0
if printf '%s\n' "$SECTION" | grep -qF 'scripts/log-handback.sh'; then
  script_count=$((script_count + 1))
fi
if printf '%s\n' "$SECTION" | grep -qF 'scripts/review-gate.sh'; then
  script_count=$((script_count + 1))
fi
if [ "$script_count" -lt 2 ]; then
  fail "Leg B: permission section must name scripts/log-handback.sh and scripts/review-gate.sh as example entrypoints (found ${script_count})"
fi

# --- Leg C: "/autopilot" named as alternative path ----------------------------
if ! printf '%s\n' "$SECTION" | grep -qF '/autopilot'; then
  fail "Leg C: permission section must name '/autopilot' (slash-command) as an alternative setup path"
fi

# --- Leg D: NEGATIVE — reject recommendation language for blanket allow-all ---
if printf '%s\n' "$SECTION" | grep -iE '(enable|use|recommend|configure|set up)[[:space:]]+(a[[:space:]]+)?blanket[[:space:]]+allow' | grep -qivE 'anti-pattern|do not|never|avoid|warning'; then
  fail "Leg D: permission section must NOT recommend blanket allow-all — found recommendation language without an anti-pattern/warning qualifier"
fi

# --- Leg E: Symptom warning + anti-pattern label ------------------------------
if ! printf '%s\n' "$SECTION" | grep -qiE '(denial|permission)[[:space:]]+storm'; then
  fail "Leg E: permission section must warn about 'denial storm' or 'permission storm'"
fi
if ! printf '%s\n' "$SECTION" | grep -qiE 'anti-pattern'; then
  fail "Leg E: permission section must explicitly label blanket allow-all as an 'anti-pattern'"
fi

# --- Leg F: Version pin — CLI 1.0.72-1 reference -----------------------------
if ! printf '%s\n' "$SECTION" | grep -qF '1.0.72-1'; then
  fail "Leg F: permission section must version-pin the observed behavior to CLI 1.0.72-1"
fi

# --- Leg G: Tool-level session approval caveat ("any options/arguments") ------
if ! printf '%s\n' "$SECTION" | grep -qiE 'any (option|argument)'; then
  fail "Leg G: permission section must note that tool-level approval applies with 'any options' or 'any arguments' for the session"
fi

# --- Leg H: NEGATIVE — must NOT contain "allowed-commands list" ---------------
if printf '%s\n' "$SECTION" | grep -qiF 'allowed-commands list'; then
  fail "Leg H: permission section must NOT reference an unsupported 'allowed-commands list'"
fi

# --- Leg I: NEGATIVE — must NOT contain "complete set" ------------------------
if printf '%s\n' "$SECTION" | grep -qiF 'complete set'; then
  fail "Leg I: permission section must NOT claim scripts are the 'complete set'"
fi

# --- Leg J: NEGATIVE — must NOT list trace-lib.sh as a command target ---------
if printf '%s\n' "$SECTION" | grep -qF 'scripts/trace-lib.sh'; then
  fail "Leg J: permission section must NOT list scripts/trace-lib.sh as a direct command target (it is source-only)"
fi

# --- Leg K: /autopilot as slash-command explicitly ----------------------------
# shellcheck disable=SC2016
if ! printf '%s\n' "$SECTION" | grep -qE '`/autopilot`'; then
  fail "Leg K: permission section must reference /autopilot as a code-formatted slash-command"
fi

# --- Leg L: NEGATIVE — must NOT claim /autopilot "grants ... blanket execution authority" ---
if printf '%s\n' "$SECTION" | grep -qiE 'grants[[:space:]]+(the[[:space:]]+agent[[:space:]]+)?blanket[[:space:]]+execution[[:space:]]+authority'; then
  fail "Leg L: permission section must NOT claim /autopilot 'grants blanket execution authority' (unsupported guarantee)"
fi

# --- Leg M: NEGATIVE — must NOT claim anything "eliminates ... prompts" -------
if printf '%s\n' "$SECTION" | grep -qiE 'eliminates[[:space:]]+(per-tool[[:space:]]+)?prompts[[:space:]]+(entirely|completely|for)'; then
  fail "Leg M: permission section must NOT claim any layer 'eliminates prompts entirely' (unsupported guarantee)"
fi

# --- Leg N: NEGATIVE — must NOT claim "sufficient coverage" or equivalent -----
if printf '%s\n' "$SECTION" | grep -qiE 'sufficient[[:space:]]+coverage'; then
  fail "Leg N: permission section must NOT claim the layers provide 'sufficient coverage' (unsupported guarantee)"
fi
if printf '%s\n' "$SECTION" | grep -qiE 'layers[[:space:]]+(above[[:space:]]+)?(provide|ensure|guarantee)[[:space:]]+(complete|full|total)'; then
  fail "Leg N: permission section must NOT claim the layers provide complete/full/total coverage (unsupported guarantee)"
fi

# --- Leg O: Provenance labels present ----------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF '(Documented)'; then
  fail "Leg O: permission section must contain at least one '(Documented)' provenance label"
fi
if ! printf '%s\n' "$SECTION" | grep -qF '(Observed'; then
  fail "Leg O: permission section must contain at least one '(Observed' provenance label"
fi

# --- Leg P: Official GitHub Docs URL citation ---------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF 'docs.github.com'; then
  fail "Leg P: permission section must cite an official GitHub Docs URL (docs.github.com)"
fi

# --- Result -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d subagent-permission-setup obligation(s) missing.\n' "$fails" >&2
  exit 1
fi

printf 'subagent-permission-setup documentation contract honored (16 legs passed)\n'
