#!/usr/bin/env bash
# test_no_runtime_refs_to_archived_evaluation_docs.sh — regression sensor for
# issue #337 feature `block-runtime-archive-refs` (epic #331, decision 3a).
#
# Feature 1 archived the zero-runtime-reference eval prose into
# docs/archive/evaluation/. This behavioral tripwire derives the archived path
# set at run time (never a hard-coded snapshot), then fails if any runtime
# surface — scripts/, .copilot/, or AGENTS.md — still names the stale
# docs/evaluation/<archived-relative-path> form, printing file:line evidence.
# A future issue that archives more docs is covered automatically.
#
# The tombstone README.md is excluded from the derived set: docs/evaluation/
# README.md is a DIFFERENT, live, runtime-referenced index page, so treating
# "README.md" as archived would flag that legitimate reference as stale.
#
# Bash 3.2 compatible. Exit 0 clean · 1 a stale reference or a self-test miss.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE_DIR="${ROOT}/docs/archive/evaluation"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

# Print every relative path under an archive root, excluding the tombstone
# README.md (a nested */README.md is a distinct path and stays included).
derive_archived_paths() {
  ( cd "$1" && find . -type f | sed 's#^\./##' | LC_ALL=C sort ) | grep -v '^README.md$'
}

# Grep scripts/, .copilot/, AGENTS.md under <root> for docs/evaluation/<rel>;
# print file:line hits and return non-zero on any hit. Returns 0 when none of
# the surfaces exist or no archived path is referenced.
scan_for_archived_refs() {
  local root="$1"; shift
  local -a targets=()
  [ -d "${root}/scripts" ] && targets+=("${root}/scripts")
  [ -d "${root}/.copilot" ] && targets+=("${root}/.copilot")
  [ -f "${root}/AGENTS.md" ] && targets+=("${root}/AGENTS.md")
  [ ${#targets[@]} -gt 0 ] || return 0
  local rel hit=0
  for rel in "$@"; do
    [ -n "$rel" ] || continue
    while IFS= read -r line; do printf '%s\n' "$line"; hit=1; done \
      < <(grep -rnF -- "docs/evaluation/${rel}" "${targets[@]}" 2>/dev/null || true)
  done
  [ "$hit" -eq 0 ]
}

archived=()
while IFS= read -r rel; do [ -n "$rel" ] && archived+=("$rel"); done \
  < <(derive_archived_paths "$ARCHIVE_DIR")
[ ${#archived[@]} -gt 0 ] \
  || fail "no archived paths derived under ${ARCHIVE_DIR} — cannot scan or self-test"

# Compact teeth: on each of the three surfaces a reference to a real archived
# path MUST trip the scanner; a preserved docs/evaluation/ path MUST NOT.
if [ ${#archived[@]} -gt 0 ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  for surface in scripts .copilot AGENTS.md; do
    root="${tmp}/pos-${surface}"
    if [ "$surface" = "AGENTS.md" ]; then
      mkdir -p "$root"; printf 'docs/evaluation/%s\n' "${archived[0]}" > "${root}/AGENTS.md"
    else
      mkdir -p "${root}/${surface}"; printf 'docs/evaluation/%s\n' "${archived[0]}" > "${root}/${surface}/note"
    fi
    scan_for_archived_refs "$root" "${archived[@]}" >/dev/null \
      && fail "self-test: a ${surface} reference to an archived path must FAIL but passed"
  done
  preserved="$(find "${ROOT}/docs/evaluation" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort | head -n1)"
  neg="${tmp}/neg"; mkdir -p "${neg}/scripts"
  printf 'docs/evaluation/%s\n' "$preserved" > "${neg}/scripts/note"
  scan_for_archived_refs "$neg" "${archived[@]}" >/dev/null \
    || fail "self-test: a preserved docs/evaluation/${preserved} reference must PASS but failed"
fi

# Real assertion: this repo's actual scripts/, .copilot/, AGENTS.md.
if ! hits="$(scan_for_archived_refs "$ROOT" "${archived[@]}")"; then
  fail "stale runtime/doctrine reference(s) to an archived docs/evaluation path:
${hits}"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d archived-evaluation-doc runtime-reference violation(s).\n' "$fails" >&2
  exit 1
fi
echo "no runtime script, .copilot doctrine file, or AGENTS.md references an archived docs/evaluation path"
