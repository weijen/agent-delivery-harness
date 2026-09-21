#!/usr/bin/env bash
# harness-sensor-trigger: maintenance
# harness-sensor-depends: scripts/maintenance/audit-sweep.sh .copilot/prompts/audit-sweep.prompt.md .copilot/skills/* docs/harness-contract.yml scripts/install-harness.assets scripts/install-harness.dev.assets tests/harness-dev-sensors.txt
# test_audit_sweep.sh — regression sensor for the local audit-sweep driver
# (issue #258): scripts/maintenance/audit-sweep.sh runs the six audit skills, one fresh
# headless `copilot -p` session each, report-only, and consolidates the
# per-skill reports into one index.md roll-up. .copilot/prompts/audit-sweep.prompt.md
# is the one-shot entry.
#
# The sensor NEVER invokes the real Copilot CLI: dry-run and consolidation stay
# offline; execution uses a fake CLI to prove root anchoring and failure status.
#
# Legs:
#   A (audit-sweep-script)        dry-run lists exactly the six audit skills,
#                                 derived from .copilot/skills/ minus the three
#                                 non-audit skills; every command denies write;
#                                 subset args filter; unknown skill fails loudly;
#                                 script is shellcheck-clean.
#   B (audit-sweep-consolidation) --consolidate builds index.md with a merged
#                                 Findings roll-up (skill,severity,priority,file)
#                                 above per-skill sections.
#   C (audit-sweep-prompt)        the prompt references the script and index.md.
#
# Exit: 0 all legs pass · 1 any obligation missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT}/scripts/maintenance/audit-sweep.sh"
PROMPT="${ROOT}/.copilot/prompts/audit-sweep.prompt.md"
SKILLS_DIR="${ROOT}/.copilot/skills"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
note() { printf 'note: %s\n' "$*" >&2; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Isolated PATH with a fake `copilot` that hard-fails if invoked ----------
BIN="${TMP_DIR}/bin"
mkdir -p "${BIN}"
cat > "${BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
echo "FAKE copilot invoked — --dry-run must NOT launch the CLI: $*" >&2
exit 97
FAKE
chmod +x "${BIN}/copilot"
for tool in bash sh env sed awk grep sort comm date mkdir cat printf dirname basename find head tr; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && ln -sf "$real" "${BIN}/$tool"
done
RUN_PATH="${BIN}:${PATH}"

# --- Expected six audit skills, derived from the skill directory -------------
# All skill subdirs minus the three non-audit skills. If this drifts from what
# the script emits, the leg-A comparison fails (drift caught both ways).
mapfile -t EXPECTED < <(
  find "${SKILLS_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
    | grep -vxE 'code-review|create-pr|public-exposure-audit|copilot-log-review' \
    | sort
)

[ -f "${SCRIPT}" ] || { fail "scripts/maintenance/audit-sweep.sh not found"; }
[ "${#EXPECTED[@]}" -eq 6 ] || note "expected six audit skills, derived ${#EXPECTED[@]}: ${EXPECTED[*]}"

# ============================================================================
# Leg A — driver behavior (--dry-run, subset, unknown, deny-write, shellcheck)
# ============================================================================
if [ -f "${SCRIPT}" ]; then
  # A1: --dry-run lists exactly the six audit skills, offline (fake copilot unused).
  dry_out="$(cd "${ROOT}" && PATH="${RUN_PATH}" bash "${SCRIPT}" --dry-run 2>&1)" || {
    fail "A1: --dry-run exited non-zero"; dry_out=""
  }
  printf '%s\n' "${dry_out}" | grep -q 'FAKE copilot invoked' \
    && fail "A1: --dry-run launched the copilot CLI (must stay offline)"

  mapfile -t GOT < <(
    for s in "${EXPECTED[@]}"; do
      printf '%s\n' "${dry_out}" | grep -q -- "$s" && printf '%s\n' "$s"
    done | sort
  )
  if [ "${#GOT[@]}" -ne "${#EXPECTED[@]}" ]; then
    fail "A1: --dry-run did not name all six audit skills (got ${#GOT[@]}: ${GOT[*]})"
  fi
  # No non-audit skill should appear as a swept skill.
  for bad in code-review create-pr public-exposure-audit; do
    printf '%s\n' "${dry_out}" | grep -qw -- "$bad" \
      && fail "A1: --dry-run swept a non-audit skill: ${bad}"
  done

  # A2: every generated command denies write.
  cmd_lines="$(printf '%s\n' "${dry_out}" | grep -c -- '--deny-tool' || true)"
  [ "${cmd_lines}" -ge 6 ] \
    || fail "A2: fewer than six commands carry --deny-tool (got ${cmd_lines})"
  # A stricter check: any line naming a skill command must include --deny-tool write.
  while IFS= read -r line; do
    case "$line" in
      *copilot*) printf '%s' "$line" | grep -q -- '--deny-tool write' \
        || fail "A2: a copilot command line omits --deny-tool write: ${line}" ;;
    esac
  done <<< "${dry_out}"

  # A3: subset selection filters correctly.
  sub_out="$(cd "${ROOT}" && PATH="${RUN_PATH}" bash "${SCRIPT}" --dry-run find-duplicates security-audit 2>&1)" \
    || fail "A3: subset --dry-run exited non-zero"
  printf '%s\n' "${sub_out}" | grep -q -- 'find-duplicates' \
    || fail "A3: subset missing find-duplicates"
  printf '%s\n' "${sub_out}" | grep -q -- 'security-audit' \
    || fail "A3: subset missing security-audit"
  printf '%s\n' "${sub_out}" | grep -qw -- 'find-over-design' \
    && fail "A3: subset leaked a non-selected skill (find-over-design)"

  # A4: unknown skill name fails loudly (non-zero + message).
  if cd "${ROOT}" && PATH="${RUN_PATH}" bash "${SCRIPT}" --dry-run not-a-real-skill >"${TMP_DIR}/unk.out" 2>&1; then
    fail "A4: unknown skill name did not fail (expected non-zero)"
  else
    grep -qi 'unknown\|not.*skill\|no such\|invalid' "${TMP_DIR}/unk.out" \
      || fail "A4: unknown skill failure was not loud (no explanatory message)"
  fi
fi

# A5: shellcheck-clean (skip if shellcheck absent).
if command -v shellcheck >/dev/null 2>&1 && [ -f "${SCRIPT}" ]; then
  shellcheck "${SCRIPT}" >"${TMP_DIR}/sc.out" 2>&1 \
    || { fail "A5: audit-sweep.sh is not shellcheck-clean"; cat "${TMP_DIR}/sc.out" >&2; }
else
  note "A5: shellcheck not available — skipping lint assertion"
fi

# ============================================================================
# Leg B — consolidation: index.md roll-up over fake per-skill reports
# ============================================================================
if [ -f "${SCRIPT}" ]; then
  RUN_DIR="${TMP_DIR}/run"
  mkdir -p "${RUN_DIR}"
  cat > "${RUN_DIR}/find-duplicates.md" <<'MD'
# find-duplicates

## Findings
| Severity | Priority | File | Finding |
| --- | --- | --- | --- |
| MAJOR | Fix now | scripts/a.sh | duplicated block |
MD
  cat > "${RUN_DIR}/security-audit.md" <<'MD'
# security-audit

## Findings
| Severity | Priority | File | Finding |
| --- | --- | --- | --- |
| CRITICAL | Fix now | scripts/b.sh | hardcoded token |
MD

  if cd "${ROOT}" && PATH="${RUN_PATH}" bash "${SCRIPT}" --consolidate "${RUN_DIR}" >"${TMP_DIR}/cons.out" 2>&1; then
    idx="${RUN_DIR}/index.md"
    [ -f "${idx}" ] || fail "B: --consolidate did not write index.md"
    if [ -f "${idx}" ]; then
      # Roll-up table keyed (skill, severity, priority, file): a Skill column header.
      grep -qiE '\|[[:space:]]*skill[[:space:]]*\|' "${idx}" \
        || fail "B: index.md roll-up table missing a Skill column"
      # Each fake finding surfaces in the roll-up prefixed with its skill.
      grep -qE 'find-duplicates.*MAJOR|MAJOR.*find-duplicates' "${idx}" \
        || fail "B: roll-up missing the find-duplicates MAJOR row"
      grep -qE 'security-audit.*CRITICAL|CRITICAL.*security-audit' "${idx}" \
        || fail "B: roll-up missing the security-audit CRITICAL row"
      # Per-skill sections present below the roll-up.
      grep -q 'find-duplicates' "${idx}" || fail "B: index.md missing find-duplicates section"
      grep -q 'security-audit' "${idx}" || fail "B: index.md missing security-audit section"
    fi
  else
    fail "B: --consolidate <dir> exited non-zero"
    cat "${TMP_DIR}/cons.out" >&2
  fi
fi

# ============================================================================
# Leg C — one-shot prompt references the script + index.md
# ============================================================================
if [ -f "${PROMPT}" ]; then
  head -1 "${PROMPT}" | grep -q -- '---' || fail "C: prompt missing YAML frontmatter"
  grep -q 'mode: *agent' "${PROMPT}" || fail "C: prompt is not mode: agent"
  grep -q 'scripts/maintenance/audit-sweep.sh' "${PROMPT}" \
    || fail "C: prompt does not reference ./scripts/maintenance/audit-sweep.sh"
  grep -q 'index.md' "${PROMPT}" || fail "C: prompt does not reference index.md"
else
  fail "C: .copilot/prompts/audit-sweep.prompt.md not found"
fi

# Canonical maintenance identities remain source-only and uniquely discovered.
for identity in scripts/maintenance/audit-sweep.sh tests/scripts/maintenance/test_audit_sweep.sh; do
  old="${identity/maintenance\//}"
  [ ! -e "${ROOT}/${old}" ] || fail "flat duplicate remains: ${old}"
  if grep -Fxq "$identity" "${ROOT}/scripts/install-harness.assets" "${ROOT}/scripts/install-harness.dev.assets"; then
    fail "maintainer asset selected for installation: ${identity}"
  fi
  awk -v path="$identity" '
    /^  - from:/ { selected=0 }
    /^    to:/ { selected=($2==path) }
    selected && /^    audience: source-only$/ { found=1 }
    END { exit !found }
  ' "${ROOT}/docs/harness-contract.yml" || fail "source-only layout identity missing: ${identity}"
done
discovered="$("${ROOT}/scripts/validation/affected-sensors.sh" --list)"
[ "$(grep -Fxc tests/scripts/maintenance/test_audit_sweep.sh <<<"$discovered")" -eq 1 ] \
  || fail "audit sensor discovery is not unique"
if grep -E '/(lib|helpers|fixtures)/' <<<"$discovered"; then fail "discovery included helper"; fi

# The real driver runs fake child processes from its checkout, not caller cwd,
# continues after a failing child and still consolidates both reports.
mkdir -p "${TMP_DIR}/unrelated cwd"
export AUDIT_PROBE_LOG="${TMP_DIR}/invocations"
cat >"${BIN}/copilot" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" >>"$AUDIT_PROBE_LOG"
case "$*" in *'--deny-tool write'*) ;; *) exit 98 ;; esac
printf '| Severity | Priority | File | Finding |\n| --- | --- | --- | --- |\n| LOW | Defer | fixture | fake report |\n'
case "$*" in *'`find-duplicates`'*) exit 17 ;; *) exit 0 ;; esac
FAKE
rc=0
(cd "${TMP_DIR}/unrelated cwd" && PATH="$RUN_PATH" AUDIT_LOG_ROOT="${TMP_DIR}/audit reports" \
  "$SCRIPT" find-duplicates security-audit) >"${TMP_DIR}/run.out" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "child failure must propagate as exit 1, got ${rc}"
[ "$(wc -l <"$AUDIT_PROBE_LOG" | tr -d ' ')" -eq 2 ] || fail "sweep did not execute both children"
if grep -Fxv "$ROOT" "$AUDIT_PROBE_LOG"; then fail "child cwd escaped command checkout"; fi
index="$(find "${TMP_DIR}/audit reports" -name index.md -print)"
[ -f "$index" ] || fail "failed child prevented consolidation"
if [ -f "$index" ]; then
  grep -Fq 'find-duplicates | LOW' "$index" || fail "failed child report lost"
  grep -Fq 'security-audit | LOW' "$index" || fail "later child report lost"
  grep -Fq 'FAILED to complete' "$index" || fail "failure marker lost"
fi
mkdir -p "${TMP_DIR}/unrelated cwd/relative reports"
printf '# A report\n' >"${TMP_DIR}/unrelated cwd/relative reports/probe.md"
(cd "${TMP_DIR}/unrelated cwd" && "$SCRIPT" --consolidate 'relative reports') >/dev/null \
  || fail "relative consolidation failed"
[ -f "${TMP_DIR}/unrelated cwd/relative reports/index.md" ] || fail "consolidation changed caller-relative argument"

if [ "${fails}" -ne 0 ]; then
  printf '\n%d audit-sweep obligation(s) failed.\n' "${fails}" >&2
  exit 1
fi
printf 'audit-sweep driver, consolidation, and prompt all honored (%d audit skills)\n' "${#EXPECTED[@]}"
