#!/usr/bin/env bash
# harness-sensor-trigger: upgrade
# harness-sensor-depends: .github/workflows/release.yml .github/workflows/python-ci.yml scripts/maintenance/sync-version.sh pyproject.toml uv.lock VERSION docs/RELEASING.md docs/harness-contract.yml scripts/install-harness.assets scripts/install-harness.dev.assets tests/harness-dev-sensors.txt
# test_release_lock_sync.sh — regression sensor for issue #455: a semantic-
# release version bump must never strand main with a stale uv.lock.
#
# Three cooperating controls are pinned:
#   1. scripts/maintenance/sync-version.sh refreshes uv.lock after mirroring VERSION —
#      guarded so environments without uv (the PSR docker action) warn and
#      skip instead of failing the release.
#   2. pyproject [tool.semantic_release].assets lists uv.lock, so a refresh
#      performed by the build_command rides the release commit.
#   3. .github/workflows/release.yml carries the post-release sync step (the
#      uv-capable safety net that auto-commits the refreshed lock).
#
# Legs:
#   A  behavioral, no uv   — in a fixture dir with a PATH lacking uv,
#                            sync-version.sh exits 0, syncs VERSION, warns
#                            that uv.lock was not refreshed
#   B  behavioral, stub uv — with a recording uv stub on PATH,
#                            sync-version.sh invokes exactly 'uv lock' and
#                            reports the refresh
#   C  behavioral, no lock — a fixture without uv.lock never invokes uv
#   D  assets contract     — pyproject assets include uv.lock (and VERSION)
#   E  workflow contract   — release.yml gates the sync step on
#                            released == 'true', checks lock consistency
#                            first, guards the empty-commit flake case, and
#                            pushes a chore(release) commit
#   F  uv version parity   — release.yml and python-ci.yml pin the SAME
#                            explicit uv via the SHA-pinned setup-uv action
#                            (fixer and checker must share one toolchain)
#
# Exit: 0 all legs pass · 1 any obligation missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SYNC="${ROOT}/scripts/maintenance/sync-version.sh"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

[ -f "$SYNC" ] || { fail "canonical version command missing"; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Minimal PATH holding only the tools sync-version.sh needs — uv deliberately
# absent unless a leg links the stub in.
BIN="${TMP_DIR}/bin"
mkdir -p "${BIN}"
for tool in bash sh sed head printf cat command; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && [ -f "$real" ] && ln -sf "$real" "${BIN}/$tool"
done
NO_UV_PATH="${BIN}"

mk_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  printf '[project]\nname = "fixture"\nversion = "9.9.9"\n' > "${dir}/pyproject.toml"
  printf '0.0.0\n' > "${dir}/VERSION"
}

# --- Leg A: uv absent -> success + warning, VERSION still synced --------------
FIX_A="${TMP_DIR}/fix-a"
mk_fixture "$FIX_A"
printf 'lockfile-content\n' > "${FIX_A}/uv.lock"
a_rc=0
a_out="$(cd "$FIX_A" && PATH="$NO_UV_PATH" bash "$SYNC" 2>&1)" || a_rc=$?
[ "$a_rc" = "0" ] \
  || fail "A: sync-version must succeed without uv on PATH (exit ${a_rc}: ${a_out})"
[ "$(cat "${FIX_A}/VERSION")" = "9.9.9" ] \
  || fail "A: VERSION must be synced even when uv is absent"
grep -q 'uv not on PATH' <<<"$a_out" \
  || fail "A: the skipped refresh must be warned, not silent"

# --- Leg B: stub uv on PATH -> exactly 'uv lock' invoked ----------------------
FIX_B="${TMP_DIR}/fix b"
mk_fixture "$FIX_B"
build_command="$(sed -n 's/^build_command = "\(.*\)"$/\1/p' "${ROOT}/pyproject.toml")"
[ "$build_command" = 'bash scripts/maintenance/sync-version.sh' ] \
  || { fail "PSR must invoke canonical version command"; exit 1; }
read -r -a build_args <<<"$build_command"
mkdir -p "${FIX_B}/scripts/maintenance"
cp "$SYNC" "${FIX_B}/scripts/maintenance/"
printf 'lockfile-content\n' > "${FIX_B}/uv.lock"
UV_LOG="${TMP_DIR}/uv-invocations"
cat > "${BIN}/uv" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${UV_LOG}"
STUB
chmod +x "${BIN}/uv"
b_out="$(cd "$FIX_B" && PATH="$NO_UV_PATH" "${build_args[@]}" 2>&1)" \
  || fail "B: sync-version must succeed with uv available"
[ -f "$UV_LOG" ] && [ "$(cat "$UV_LOG")" = "lock" ] \
  || fail "B: exactly 'uv lock' must be invoked (got: $(cat "$UV_LOG" 2>/dev/null || echo none))"
grep -q 'uv.lock refreshed' <<<"$b_out" \
  || fail "B: the refresh must be reported"
[ "$(cat "${FIX_B}/VERSION")" = "9.9.9" ] || fail "B: configured build must update caller's VERSION"

cat >"${BIN}/uv" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${UV_LOG}"
exit 23
STUB
failure_rc=0
failure_out="$(cd "$FIX_B" && PATH="$NO_UV_PATH" "${build_args[@]}" 2>&1)" || failure_rc=$?
[ "$failure_rc" -eq 23 ] || fail "B: uv failure status must propagate unchanged"
if grep -q 'uv.lock refreshed' <<<"$failure_out"; then fail "B: failed refresh reported success"; fi

# --- Leg C: no uv.lock in the tree -> uv never invoked ------------------------
FIX_C="${TMP_DIR}/fix-c"
mk_fixture "$FIX_C"
: > "$UV_LOG"
(cd "$FIX_C" && PATH="$NO_UV_PATH" bash "$SYNC" >/dev/null 2>&1) \
  || fail "C: sync-version must succeed without a uv.lock"
[ ! -s "$UV_LOG" ] \
  || fail "C: uv must not be invoked when the tree has no uv.lock"
rm -f "${BIN}/uv"

# --- Leg D: PSR assets contract ----------------------------------------------
assets_line="$(grep -E '^assets[[:space:]]*=' "${ROOT}/pyproject.toml" || true)"
grep -q '"uv.lock"' <<<"$assets_line" \
  || fail "D: [tool.semantic_release].assets must include uv.lock"
grep -q '"VERSION"' <<<"$assets_line" \
  || fail "D: [tool.semantic_release].assets must keep VERSION"

# --- Leg E: release workflow safety-net contract ------------------------------
WF="${ROOT}/.github/workflows/release.yml"
grep -q 'Sync uv.lock with the released version' "$WF" \
  || fail "E: release.yml must carry the post-release lock sync step"
# The full step block: from its name line to the next step's dash-name line —
# robust to key ordering inside the step (review nit: -A windows false-fail on
# cosmetic refactors).
sync_block="$(awk '/Sync uv.lock with the released version/{grab=1} grab{print} grab && /^      - name:/ && !/Sync uv.lock/{exit}' "$WF")"
grep -q "released == 'true'" <<<"$sync_block" \
  || fail "E: the sync step must be gated on released == 'true'"
grep -q 'uv lock --check' <<<"$sync_block" \
  || fail "E: the sync step must no-op when the lock is already consistent"
grep -q 'git diff --quiet -- uv.lock' <<<"$sync_block" \
  || fail "E: a --check flake with an unchanged lock must not attempt an empty commit"
grep -q 'chore(release): sync uv.lock' <<<"$sync_block" \
  || fail "E: the sync step must commit the refreshed lock as chore(release)"

# --- Leg F: fixer/checker uv version parity (UV-LOCK-AUTHORITY-VERSION-SKEW) --
CI_WF="${ROOT}/.github/workflows/python-ci.yml"
uv_pins="$(grep -h -A8 'astral-sh/setup-uv@' "$WF" "$CI_WF" \
  | sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' | sort -u)"
[ "$(wc -l <<<"$uv_pins" | tr -d ' ')" = "1" ] && [ -n "$uv_pins" ] \
  || fail "F: release.yml and python-ci.yml must pin the SAME explicit uv version (got: $(tr '\n' ' ' <<<"$uv_pins"))"
grep -q 'astral-sh/setup-uv@d4b2f3b' "$WF" \
  || fail "F: the release sync must provision uv via the SHA-pinned setup-uv action, not pip"

for identity in scripts/maintenance/sync-version.sh \
  tests/scripts/maintenance/test_release_workflow.sh tests/scripts/maintenance/test_release_lock_sync.sh; do
  [ ! -e "${ROOT}/${identity/maintenance\//}" ] || fail "flat release duplicate remains"
  if grep -Fxq "$identity" "${ROOT}/scripts/install-harness.assets" "${ROOT}/scripts/install-harness.dev.assets"; then
    fail "source-only release asset selected for installation: ${identity}"
  fi
done
discovered="$("${ROOT}/scripts/validation/affected-sensors.sh" --list)"
for sensor in test_release_workflow.sh test_release_lock_sync.sh; do
  [ "$(grep -Fxc "tests/scripts/maintenance/${sensor}" <<<"$discovered")" -eq 1 ] \
    || fail "release sensor discovery is not unique: ${sensor}"
done
if grep -E '/(lib|helpers|fixtures)/' <<<"$discovered"; then fail "discovery included helper"; fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d release-lock-sync obligation(s) failed.\n' "$fails" >&2
  exit 1
fi
printf 'release lock sync honored (guarded refresh, assets, workflow safety net)\n'
