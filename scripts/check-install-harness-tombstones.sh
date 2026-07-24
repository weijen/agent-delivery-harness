#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LEDGER="${ROOT}/scripts/install-harness.tombstones"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ "$#" -le 1 ] || fail "usage: check-install-harness-tombstones.sh [repository-root]"
[ -f "$LEDGER" ] || fail "tombstone ledger missing: $LEDGER"
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "not a git repository: $ROOT"

shallow="$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" \
  || fail "cannot determine repository history depth"
[ "$shallow" = "false" ] \
  || fail "shallow checkout — cannot validate tombstones; fetch full history"

installer_history="$(git -C "$ROOT" log \
  --diff-filter=A --format=%H --reverse -- scripts/install-harness.sh)" \
  || fail "cannot inspect installer history"
start_commit="${installer_history%%$'\n'*}"
[ -n "$start_commit" ] || fail "could not locate installer introduction commit"

ledger_entries="$(grep -Evc '^[[:space:]]*(#|$)' "$LEDGER" || true)"
range_count="$(git -C "$ROOT" rev-list --count "${start_commit}..HEAD")" \
  || fail "cannot inspect managed deletion history"
if [ "$ledger_entries" -gt 0 ] && [ "$range_count" -eq 0 ]; then
  fail "managed deletion history is empty while the tombstone ledger is non-empty"
fi

git -C "$ROOT" log --diff-filter=D --format= --name-only "${start_commit}..HEAD" -- \
  scripts profiles tests .copilot .github/workflows docs VERSION .env.example |
  sort -u |
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ ! -e "${ROOT}/${path}" ] || continue
    case "$path" in
      .github/workflows/*)
        [ "$path" = ".github/workflows/harness-smoke.yml" ] || continue
        ;;
      docs/*)
        case "$path" in
          docs/HARNESS.md | docs/getting-started.md | docs/multi-language-profiles.md | \
            docs/harness-contract.yml | docs/RELEASING.md | docs/evaluation/* | docs/runtime-adapters/*) ;;
          *) continue ;;
        esac
        ;;
    esac

    deletion_commit="$(git -C "$ROOT" log \
      --full-history --diff-filter=D -1 --format=%H -- "$path" </dev/null)"
    [ -n "$deletion_commit" ] || fail "cannot locate deletion commit for $path"
    blob="${deletion_commit}^:${path}"
    digest="$(git -C "$ROOT" show "$blob" </dev/null | shasum -a 256 | awk '{print $1}')"
    printf '%s\t%s\n' "$digest" "$path"
  done |
  sort >"${TMP_DIR}/expected"

grep -Ev '^[[:space:]]*(#|$)' "$LEDGER" | sort >"${TMP_DIR}/actual"

if grep -Ev '^[0-9a-f]{64}[[:space:]][^/[:space:]][^[:space:]]*$' \
  "${TMP_DIR}/actual" >"${TMP_DIR}/malformed" &&
  [ -s "${TMP_DIR}/malformed" ]; then
  fail "tombstone ledger contains a malformed digest or path"
fi
if [ "$(wc -l <"${TMP_DIR}/actual" | tr -d ' ')" -ne \
  "$(sort -u "${TMP_DIR}/actual" | wc -l | tr -d ' ')" ]; then
  fail "tombstone ledger contains duplicate entries"
fi
if ! comm -23 "${TMP_DIR}/expected" "${TMP_DIR}/actual" >"${TMP_DIR}/missing" ||
  [ -s "${TMP_DIR}/missing" ]; then
  cat "${TMP_DIR}/missing"
  fail "tombstone ledger is missing managed deletion history"
fi

printf 'install-harness tombstone manifest sensor passed\n'
