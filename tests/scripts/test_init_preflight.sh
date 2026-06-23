#!/usr/bin/env bash
# Regression sensor for scripts/init.sh PREFLIGHT semantics (the non-gate checks).
# init.sh is a sensor: it must HARD-FAIL on a broken environment and WARN (exit 0)
# on soft/optional gaps. This test drives those branches deterministically with a
# restricted PATH plus fake `gh` / `az` binaries, so the result does not depend on
# the developer's real login state or installed toolchain.
#
# Covered:
#   * GitHub auth failure is a HARD failure (exit 1).
#   * Azure auth is OPTIONAL by default (warn, exit 0) but HARD with REQUIRE_AZ=1.
#   * Commit signing disabled is a WARNING (exit 0).
#   * A detected language surface whose tool is absent is a WARNING (exit 0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Restricted bin: real coreutils + git, plus controllable fake gh / az -----
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for tool in bash sh env git basename dirname find grep sed tr cut head cat rm mkdir ls uname awk sleep printf; do
  p="$(command -v "$tool" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${tool}"
done

# gh: `auth status` succeeds only when GH_AUTH_OK=1 (default 1); api user prints a login.
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") [ "${GH_AUTH_OK:-1}" = "1" ] ; exit ;;
  "api user")    printf 'fixture-user\n' ; exit 0 ;;
esac
exit 1
SH
chmod +x "${BIN}/gh"

# az: `account show` succeeds only when AZ_OK=1 (default 1).
cat > "${BIN}/az" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "account" ] && [ "$2" = "show" ]; then
  [ "${AZ_OK:-1}" = "1" ] || exit 1
  printf 'fixture-sub\n'
  exit 0
fi
exit 0
SH
chmod +x "${BIN}/az"

# new_repo <name> — a fresh docs-only git repo carrying a copy of init.sh.
new_repo() {
  local dir="${TMP_DIR}/$1"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/init.sh" "${dir}/scripts/init.sh"
  cp -R "${ROOT}/profiles" "${dir}/profiles"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign true   # signing ON unless a test turns it off
  printf 'fixture\n' > "${dir}/README.md"
  printf '%s' "$dir"
}

# run_init <repo> — run init.sh under the restricted PATH; capture output + status.
# Extra VAR=VAL args are exported for the run. Echoes the exit code; writes
# combined output to $OUT.
OUT="${TMP_DIR}/out.txt"
run_init() {
  local dir="$1"; shift
  ( cd "$dir"
    for kv in "$@"; do export "${kv?}"; done
    PATH="${BIN}" ./scripts/init.sh
  ) >"$OUT" 2>&1
}

# --- 1. GitHub auth failure is HARD ------------------------------------------
r="$(new_repo gh-hard)"
if run_init "$r" GH_AUTH_OK=0; then
  cat "$OUT"; fail "gh auth failure must be a hard failure (exit 1)"
fi
grep -qi "gh not authenticated" "$OUT" || { cat "$OUT"; fail "missing gh-not-authenticated message"; }

# --- 2a. Azure optional by default (warn, exit 0) ----------------------------
r="$(new_repo az-default)"
if ! run_init "$r" AZ_OK=0; then
  cat "$OUT"; fail "az failure must NOT block by default (expected exit 0 warning)"
fi
grep -qi "az not authenticated" "$OUT" || { cat "$OUT"; fail "missing az optional warning"; }

# --- 2b. Azure hard with REQUIRE_AZ=1 ----------------------------------------
r="$(new_repo az-required)"
if run_init "$r" AZ_OK=0 REQUIRE_AZ=1; then
  cat "$OUT"; fail "REQUIRE_AZ=1 with az down must be a hard failure"
fi
grep -qi "REQUIRE_AZ=1" "$OUT" || { cat "$OUT"; fail "missing REQUIRE_AZ hard-fail message"; }

# --- 3. Commit signing disabled is a WARNING ---------------------------------
r="$(new_repo signing)"
git -C "$r" config commit.gpgsign false
if ! run_init "$r"; then
  cat "$OUT"; fail "disabled commit signing must warn, not fail"
fi
grep -qi "commit signing not enabled" "$OUT" || { cat "$OUT"; fail "missing commit-signing warning"; }

# --- 4. Detected surface whose tool is absent is a WARNING -------------------
# go.mod present but `go` is not on the restricted PATH -> warn, exit 0.
r="$(new_repo go-missing)"
printf 'module fixture\n' > "${r}/go.mod"
if ! run_init "$r"; then
  cat "$OUT"; fail "missing language tool must warn, not fail"
fi
grep -qi "Go surface detected" "$OUT" || { cat "$OUT"; fail "missing Go surface detection"; }
grep -qi "go is not installed" "$OUT" || { cat "$OUT"; fail "missing 'go not installed' warning"; }

printf 'init preflight checks passed\n'
