#!/usr/bin/env bash
# test_copilot_log_review_registered.sh — regression sensor for issue #306,
# feature log-review-skill-registered: the new report-only `copilot-log-review`
# skill skeleton exists with valid customization frontmatter, and it is
# registered as a NON_AUDIT skill so the local audit-sweep driver never runs it.
#
# Legs:
#   A (skill-skeleton)   .copilot/skills/copilot-log-review/SKILL.md exists and
#                        passes the shared customization frontmatter validator.
#   B (non-audit-array)  scripts/audit-sweep.sh declares copilot-log-review in
#                        its NON_AUDIT array.
#   C (excluded-sweep)   audit-sweep.sh --dry-run does NOT name copilot-log-review
#                        (offline: a fake `copilot` that hard-fails proves the
#                        dry-run never launches the CLI).
#
# Exit: 0 all legs pass · 1 any obligation missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="${ROOT}/.copilot/skills/copilot-log-review/SKILL.md"
SWEEP="${ROOT}/scripts/audit-sweep.sh"
VALIDATOR="${ROOT}/tests/evals/bin/validate-customization-frontmatter.sh"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

# --- Leg A: skeleton exists and frontmatter validates -----------------------
if [ ! -f "${SKILL}" ]; then
  fail "A: skill skeleton not found (${SKILL})"
else
  if [ ! -x "${VALIDATOR}" ] && [ ! -f "${VALIDATOR}" ]; then
    fail "A: frontmatter validator not found (${VALIDATOR})"
  elif ! bash "${VALIDATOR}" "${SKILL}" >/dev/null 2>&1; then
    fail "A: copilot-log-review SKILL.md fails the customization frontmatter validator"
  fi
fi

# --- Leg B: registered in the NON_AUDIT array -------------------------------
if [ ! -f "${SWEEP}" ]; then
  fail "B: scripts/audit-sweep.sh not found (${SWEEP})"
else
  # The NON_AUDIT array declaration line must list copilot-log-review.
  if ! grep -E '^NON_AUDIT=\(' "${SWEEP}" | grep -q 'copilot-log-review'; then
    fail "B: copilot-log-review is not in the NON_AUDIT array in audit-sweep.sh"
  fi
fi

# --- Leg C: excluded from the sweep (offline dry-run) -----------------------
if [ -f "${SWEEP}" ]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT
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
  run_path="${BIN}:${PATH}"

  dry_out="$(cd "${ROOT}" && PATH="${run_path}" bash "${SWEEP}" --dry-run 2>&1)" || {
    fail "C: --dry-run exited non-zero"
    dry_out=""
  }
  if printf '%s\n' "${dry_out}" | grep -q 'FAKE copilot invoked'; then
    fail "C: --dry-run launched the copilot CLI (must stay offline)"
  fi
  if printf '%s\n' "${dry_out}" | grep -q 'copilot-log-review'; then
    fail "C: --dry-run swept copilot-log-review (must be excluded as non-audit)"
  fi
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d copilot-log-review registration obligation(s) failed.\n' "${fails}" >&2
  exit 1
fi
printf 'copilot-log-review skeleton, NON_AUDIT registration, and sweep exclusion all honored\n'
