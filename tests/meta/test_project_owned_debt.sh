#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'project-owned-debt: %s\n' "$*" >&2; exit 1; }

tracker="${ROOT}/docs/tech-debt-tracker.md"
policy="${ROOT}/.copilot/instructions/harness.instructions.md"
active="$(awk '/^## Active/ {capture=1; next} capture && /^## / {exit} capture' "$tracker")"
resolved="$(awk '/^## Resolved/ {capture=1; next} capture && /^## / {exit} capture' "$tracker")"
grep -q '^## Active' "$tracker" || fail "tracker must distinguish active findings"
grep -qF 'TD-001' <<<"$resolved" || fail "obsolete hook finding must be resolved"
if grep -qF 'TD-001' <<<"$active"; then
  fail "removed hook must not remain active debt"
fi
if grep -qiE 'hook[-_]liveness' "${ROOT}/scripts/lifecycle/start-issue.sh"; then
  fail "TD-001 cannot be resolved while its hook-liveness mechanism remains"
fi
grep -qF 'create on first use' "$policy" || fail "on-demand debt policy missing"
grep -qF 'project-owned' "$policy" || fail "debt ownership policy missing"
for requirement in 'clearing condition' "human's agreement" 'Minor / Low'; do
  grep -qF "$requirement" "$policy" || fail "deferral rule missing: ${requirement}"
done

target="${TMP_DIR}/adopter"
# Keep the real unselected tracker beside the bounded installer payload.
# shellcheck source=tests/scripts/lib/installer-fixture.sh
source "${ROOT}/tests/scripts/lib/installer-fixture.sh"
installer_fixture_source "${TMP_DIR}/source"
cp "$tracker" "${TMP_DIR}/source/docs/tech-debt-tracker.md"
installer="${TMP_DIR}/source/scripts/install-harness.sh"
bash "$installer" "$target" --write >"${TMP_DIR}/install.log" 2>&1 \
  || { cat "${TMP_DIR}/install.log" >&2; fail "fresh install failed"; }
[ ! -e "${target}/docs/tech-debt-tracker.md" ] \
  || fail "fresh adopter must not inherit this repository's debt"
mkdir -p "${target}/docs"
printf '# Adopter-owned debt\n\nKeep this finding.\n' >"${TMP_DIR}/expected"
cp "${TMP_DIR}/expected" "${target}/docs/tech-debt-tracker.md"
bash "$installer" "$target" --update >"${TMP_DIR}/update.log" 2>&1 \
  || { cat "${TMP_DIR}/update.log" >&2; fail "update failed"; }
cmp -s "${TMP_DIR}/expected" "${target}/docs/tech-debt-tracker.md" \
  || fail "update must preserve adopter-owned debt"

printf 'project-owned on-demand debt contract honored\n'
