#!/usr/bin/env bash
set -euo pipefail
SHELLCHECK_VERSION_PIN=0.11.0
SHELLCHECK_SHA256_PIN=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
UV_VERSION_PIN=0.12.3
UV_SHA256_PIN=600cf9a742aca00d292673b16b5acffaa7b8c269a364ad0c2e79498dcb1fe101
fail() { printf 'install-ci-tool: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail "usage: install-ci-tool.sh shellcheck|uv"
tool="$1"
os="$(uname -s)"; arch="$(uname -m)"
[ "$os" = Linux ] && [ "$arch" = x86_64 ] || fail "unsupported platform: $os/$arch"
case "$tool" in
  shellcheck)
    version="$SHELLCHECK_VERSION_PIN"; digest="$SHELLCHECK_SHA256_PIN"
    [ "${SHELLCHECK_VERSION:-$version}" = "$version" ] || fail "ShellCheck workflow pin differs from installer"
    [ "${SHELLCHECK_SHA256:-$digest}" = "$digest" ] || fail "ShellCheck workflow checksum differs from installer"
    asset=279056942; repository=koalaman/shellcheck; directory="shellcheck-v${version}"
    binaries=(shellcheck) ;;
  uv)
    version="$UV_VERSION_PIN"; digest="$UV_SHA256_PIN"
    [ "${UV_VERSION:-$version}" = "$version" ] || fail "uv workflow pin differs from installer"
    asset=505387817; repository=astral-sh/uv; directory=uv-x86_64-unknown-linux-gnu
    binaries=(uv uvx) ;;
  *) fail "unknown tool: $tool" ;;
esac
[ -n "${RUNNER_TEMP:-}" ] && [ -n "${GITHUB_PATH:-}" ] || fail "RUNNER_TEMP and GITHUB_PATH are required"
cache="${HOME}/.cache/harness-ci-tools"
mkdir -p "$cache" "$RUNNER_TEMP"
archive="${cache}/${tool}-${version}-${os}-${arch}-${digest}.tar"
TMP_DIR="$(mktemp -d "${RUNNER_TEMP}/ci-tool.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
verify() {
  printf '%s  %s\n' "$digest" "$1" | shasum -a 256 --check - \
    || fail "$tool archive checksum mismatch"
}
if [ -f "$archive" ]; then
  verify "$archive"
  printf 'Verified cached %s %s\n' "$tool" "$version"
else
  headers=(--header 'Accept: application/octet-stream')
  if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    # Fixed public tool assets use the supplied CI service token, not a
    # developer account binding. Repository lifecycle operations stay separate.
    headers+=(--header "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
  fi
  downloaded=0
  for attempt in 1 2 3; do
    status=0
    http="$(curl --fail --location --silent --show-error \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 5 --max-time 20 "${headers[@]}" \
      "https://api.github.com/repos/${repository}/releases/assets/${asset}" \
      --output "${TMP_DIR}/download" --write-out '%{http_code}')" || status=$?
    if [ "$status" -eq 0 ]; then downloaded=1; break; fi
    printf 'API download failed: tool=%s attempt=%s HTTP=%s curl=%s\n' "$tool" "$attempt" "$http" "$status" >&2
    case "$status:$http" in
      6:*|7:*|28:*|22:408|22:429|22:500|22:502|22:503|22:504) ;;
      *) fail "$tool download failed permanently" ;;
    esac
    [ "$attempt" -eq 3 ] || sleep 1
  done
  [ "$downloaded" -eq 1 ] || fail "$tool download exhausted three attempts"
  verify "${TMP_DIR}/download"
  mv "${TMP_DIR}/download" "$archive"
fi
tar -xf "$archive" -C "$TMP_DIR"
bin="${RUNNER_TEMP}/harness-ci-bin"
mkdir -p "$bin"
for binary in "${binaries[@]}"; do
  install -m 755 "${TMP_DIR}/${directory}/${binary}" "${bin}/${binary}"
done
output="$("${bin}/${tool}" --version)"
case "$tool" in
  shellcheck) actual="$(awk '$1 == "version:" {print $2; exit}' <<<"$output")" ;;
  uv) actual="$(awk '$1 == "uv" {print $2; exit}' <<<"$output")" ;;
esac
[ "$actual" = "$version" ] || fail "$tool version mismatch: expected $version, got $actual"
printf '%s\n' "$bin" >>"$GITHUB_PATH"
printf 'Installed %s %s from verified archive\n' "$tool" "$version"
