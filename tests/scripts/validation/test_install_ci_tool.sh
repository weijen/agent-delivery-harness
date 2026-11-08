#!/usr/bin/env bash
# hermetic API/cache installation behavior, including exact retry limits.
# harness-sensor-depends: scripts/install/install-ci-tool.sh .github/workflows/*.yml profiles/adopter-smoke.yml scripts/install-harness.assets
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'ci-tools: %s\n' "$*" >&2; exit 1; }
[ -x "$ROOT/scripts/install/install-ci-tool.sh" ] || fail "shared CI tool installer missing"
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) printf '%s\n' "${TEST_OS:-Linux}" ;; -m) echo x86_64 ;; esac
SH
cat >"$TMP_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TMP_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
n="$(cat "$CALLS")"; n=$((n + 1)); printf '%s\n' "$n" >"$CALLS"
output=""
connect=0; limit=0; accept=0; redirected=0; authenticated=0; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --connect-timeout) [ "$2" = 5 ]; connect=1; shift 2 ;;
    --max-time) [ "$2" = 20 ]; limit=1; shift 2 ;;
    --proto|--proto-redir) [ "$2" = '=https' ]; shift 2 ;;
    https://api.github.com/repos/*/releases/assets/*) url="$1"; shift ;;
    https://*) exit 88 ;;
    --header)
      if [ "$2" = 'Accept: application/octet-stream' ]; then accept=1
      else
        [ "${TEST_AUTH:-0}" = 1 ] && [ "$2" = 'Authorization: Bearer fixture-token' ]
        [ -f "$RUNNER_TEMP/identity-activated" ]; authenticated=1
      fi
      shift 2 ;;
    --write-out) [ "$2" = '%{http_code}' ]; shift 2 ;;
    --location) redirected=1; shift ;;
    --fail|--silent|--show-error) shift ;;
    *) exit 89 ;;
  esac
done
[ "$url" = "$EXPECTED_URL" ] && [ "$connect:$limit:$accept:$redirected" = 1:1:1:1 ]
[ "$authenticated" = "${TEST_AUTH:-0}" ]
case "$SCENARIO" in
  exhausted) printf 504; exit 22 ;;
  permanent) printf 404; exit 22 ;;
  transient) if [ "$n" = 1 ]; then printf 504; exit 22; fi ;;
esac
cp "$ARCHIVE" "$output"
printf 200
SH
chmod +x "$TMP_DIR/bin/"*
export PATH="$TMP_DIR/bin:$PATH"
unset GH_TOKEN GITHUB_TOKEN XDG_CACHE_HOME SHELLCHECK_VERSION SHELLCHECK_SHA256 UV_VERSION

for tool in shellcheck uv; do
  case "$tool" in
    shellcheck)
      version=0.11.0; directory=shellcheck-v0.11.0
      export EXPECTED_URL=https://api.github.com/repos/koalaman/shellcheck/releases/assets/279056942
      original=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
    uv)
      version=0.12.3; directory=uv-x86_64-unknown-linux-gnu
      export EXPECTED_URL=https://api.github.com/repos/astral-sh/uv/releases/assets/505387817
      original=600cf9a742aca00d292673b16b5acffaa7b8c269a364ad0c2e79498dcb1fe101 ;;
  esac
  fixture="$TMP_DIR/$tool"
  mkdir -p "$fixture/payload/$directory" "$fixture/scripts/install"
  if [ "$tool" = shellcheck ]; then
    printf '#!/usr/bin/env bash\nprintf "version: 0.11.0\\n"\n' >"$fixture/payload/$directory/shellcheck"
  else
    printf '#!/usr/bin/env bash\nprintf "uv 0.12.3\\n"\n' >"$fixture/payload/$directory/uv"
    cp "$fixture/payload/$directory/uv" "$fixture/payload/$directory/uvx"
  fi
  chmod +x "$fixture/payload/$directory/"*
  export ARCHIVE="$fixture/archive.tar"
  tar -cf "$ARCHIVE" -C "$fixture/payload" "$directory"
  digest="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  sed "s/$original/$digest/" "$ROOT/scripts/install/install-ci-tool.sh" >"$fixture/scripts/install/install-ci-tool.sh"
  chmod +x "$fixture/scripts/install/install-ci-tool.sh"
  export CALLS="$fixture/calls" SCENARIO=transient HOME="$fixture/home" RUNNER_TEMP="$fixture/run" GITHUB_PATH="$fixture/path"
  mkdir -p "$HOME" "$RUNNER_TEMP"
  printf '0\n' >"$CALLS"; : >"$GITHUB_PATH"
  "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1 || { cat "$fixture/out" >&2; fail "$tool transient install"; }
  [ "$(cat "$CALLS")" = 2 ] || fail "$tool transient failure was not retried once"
  [ -s "$GITHUB_PATH" ] || fail "$tool successful install omitted PATH"
  SCENARIO=exhausted "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1 \
    || fail "$tool verified cache hit contacted network"
  [ "$(cat "$CALLS")" = 2 ] || fail "$tool cache hit downloaded again"
  cache="$(find "$HOME/.cache/harness-ci-tools" -type f)"
  [ "$(basename "$cache")" = "${tool}-${version}-Linux-x86_64-${digest}.tar" ] || fail "cache identity lacks tool/version/platform/checksum"
  printf corrupt >"$cache"; : >"$GITHUB_PATH"
  if "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1; then fail "$tool corrupt cache accepted"; fi
  [ "$(cat "$CALLS")" = 2 ] && [ ! -s "$GITHUB_PATH" ] || fail "$tool corrupt cache silently recovered or exposed PATH"
  rm "$cache"
  for scenario in exhausted permanent; do
    printf '0\n' >"$CALLS"; : >"$GITHUB_PATH"
    if SCENARIO="$scenario" "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1; then fail "$tool $scenario accepted"; fi
    expected=3; [ "$scenario" != permanent ] || expected=1
    [ "$(cat "$CALLS")" = "$expected" ] || fail "$tool $scenario retry limit"
    [ ! -s "$GITHUB_PATH" ] || fail "$tool download failure exposed PATH"
  done
  mkdir -p "$fixture/scripts/lib"
  cat >"$fixture/scripts/lib/github-identity-lib.sh" <<'SH'
#!/usr/bin/env bash
harness_identity_activate() { touch "$RUNNER_TEMP/identity-activated"; }
SH
  printf '0\n' >"$CALLS"
  TEST_AUTH=1 GITHUB_TOKEN=fixture-token SCENARIO=success \
    "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1 \
    || fail "$tool authenticated API installation"
  if grep -Fq fixture-token "$fixture/out"; then fail "$tool token leaked to diagnostics"; fi
  rm "$cache"; : >"$GITHUB_PATH"
  printf '#!/usr/bin/env bash\nprintf "%s 9.9.9\\n"\n' \
    "$([ "$tool" = shellcheck ] && printf version: || printf uv)" >"$fixture/payload/$directory/$tool"
  tar -cf "$ARCHIVE" -C "$fixture/payload" "$directory"
  wrong_digest="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  sed "s/$original/$wrong_digest/" "$ROOT/scripts/install/install-ci-tool.sh" >"$fixture/scripts/install/install-ci-tool.sh"
  printf '0\n' >"$CALLS"
  if SCENARIO=success "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1; then fail "$tool wrong binary version accepted"; fi
  grep -Fq 'version mismatch' "$fixture/out" || fail "$tool version failure omitted diagnostics"
  [ ! -s "$GITHUB_PATH" ] || fail "$tool wrong version exposed PATH"
  rm "$HOME/.cache/harness-ci-tools/${tool}-${version}-Linux-x86_64-${wrong_digest}.tar"
  sed "s/$original/$digest/" "$ROOT/scripts/install/install-ci-tool.sh" >"$fixture/scripts/install/install-ci-tool.sh"
  printf corrupt >"$ARCHIVE"; printf '0\n' >"$CALLS"
  if SCENARIO=success "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1; then fail "$tool bad download accepted"; fi
  [ -z "$(find "$HOME/.cache/harness-ci-tools" -type f)" ] || fail "$tool bad download cached"
  if TEST_OS=Darwin "$fixture/scripts/install/install-ci-tool.sh" "$tool" >"$fixture/out" 2>&1; then fail "unsupported platform accepted"; fi
done
for workflow in .github/workflows/harness-smoke.yml profiles/adopter-smoke.yml \
  .github/workflows/python-ci.yml .github/workflows/release.yml; do
  if [ ! -f "$ROOT/$workflow" ]; then
    case "$workflow" in
      .github/workflows/python-ci.yml|.github/workflows/release.yml)
        printf 'SKIP source-only workflow not installed: %s\n' "$workflow"; continue ;;
      *) fail "required workflow missing: $workflow" ;;
    esac
  fi
  grep -Fq 'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' "$ROOT/$workflow" \
    || fail "$workflow omitted SHA-pinned archive cache"
  grep -Fq "hashFiles('scripts/install/install-ci-tool.sh'" "$ROOT/$workflow" \
    || fail "$workflow cache key omitted tool pins/checksums"
  if grep -Eq 'releases/download|astral-sh/setup-uv@' "$ROOT/$workflow"; then fail "$workflow retains release-web bootstrap"; fi
done
printf 'CI tool API/cache failure protection passed\n'
