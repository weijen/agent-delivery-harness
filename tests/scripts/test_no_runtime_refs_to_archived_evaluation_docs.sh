#!/usr/bin/env bash
# test_no_runtime_refs_to_archived_evaluation_docs.sh — regression sensor for
# issue #337 feature `block-runtime-archive-refs` (epic #331, decision 3a).
#
# Feature 1 archived the zero-runtime-reference eval-platform prose out of
# docs/evaluation/ into docs/archive/evaluation/. This sensor is the
# forward-looking tripwire the issue's own "RULE, not fixed list" philosophy
# demands applied to itself: it derives the archived path set by LISTING
# docs/archive/evaluation/ at run time (never a hard-coded snapshot), then
# fails if any file under scripts/, .copilot/, or AGENTS.md still names the
# stale `docs/evaluation/<archived-relative-path>` form. A future issue that
# archives more docs is covered automatically — no sensor edit required.
#
# The one basename excluded from the derived set is the archive's own
# top-level tombstone, docs/archive/evaluation/README.md. It is the archive's
# index page, not a stale-reference target: docs/evaluation/README.md is a
# DIFFERENT, live file (the runtime-referenced evaluation-doc index — see
# AGENTS.md's own "Harness evaluation strategy" row and
# scripts/install-harness.sh) that legitimately keeps being referenced by
# that exact path. Treating "README.md" as an archived relative path would
# make this sensor flag that live, correct reference as if it were stale.
#
# Contract under test:
#   1. `derive_archived_relative_paths <archive-root>` prints every relative
#      path under <archive-root>, excluding the top-level tombstone
#      README.md.
#   2. `scan_for_archived_refs <scan-root> <archived-relative-path>...` greps
#      exactly scripts/, .copilot/, and AGENTS.md under <scan-root> — no
#      other surface — for the literal `docs/evaluation/<archived-relative-path>`
#      form, prints offending file:line evidence, and returns non-zero on any
#      hit; returns 0 when none of the three surfaces exist or no hit occurs.
#   3. Teeth proof (synthetic scratch trees under mktemp, run before the real
#      assertion, independent of the live repo's current clean state —
#      mirrors test_l0_manifests.sh's inline resolver self-check pattern):
#        a. a scripts/ file naming a real archived path   -> scan must FAIL
#        b. a .copilot/ file naming a real archived path   -> scan must FAIL
#        c. an AGENTS.md naming a real archived path        -> scan must FAIL
#        d. scripts/ + .copilot/ + AGENTS.md all naming only a real,
#           currently PRESERVED docs/evaluation/ path        -> scan must PASS
#      (a)-(c) prove the scanner is capable of failing, on each of the three
#      scan surfaces independently; (d) proves it does not false-positive on
#      a preserved path even when all three surfaces reference it.
#   4. Real assertion: scan_for_archived_refs against this repo's actual
#      scripts/, .copilot/, AGENTS.md, with the live derived archived set,
#      returns zero hits — feature 1's move left no dangling runtime/doctrine
#      reference, and this sensor makes that permanent going forward.
#
# RED (teeth self-test, deterministic regardless of repo state): fixtures
# 3a-3c fail scan_for_archived_refs by construction — reverting any of them
# to reference the preserved path instead would turn that expected FAIL into
# an unexpected PASS, which run_self_test below catches.
# GREEN: fixture 3d passes; the real assertion (4) currently passes because
# feature 1's move left no runtime/doctrine reference behind.
#
# Exit codes: 0 self-test teeth confirmed AND no real archived-path reference
# found · 1 a self-test behaved unexpectedly, or a real archived-path
# reference was found (offending file:line printed above the summary).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE_DIR="${ROOT}/docs/archive/evaluation"
EVALUATION_DIR="${ROOT}/docs/evaluation"
TOMBSTONE_BASENAME="README.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# derive_archived_relative_paths <archive-root> — prints, one per line, every
# relative path under <archive-root>, excluding the top-level tombstone
# README.md (the archive's own index page, never a stale-reference target).
# A nested file that happens to share that basename (e.g.
# dashboards/README.md) is a distinct relative path and stays included.
derive_archived_relative_paths() {
  local archive_root="$1"
  [ -d "$archive_root" ] || return 1
  while IFS= read -r rel; do
    [ "$rel" = "$TOMBSTONE_BASENAME" ] && continue
    printf '%s\n' "$rel"
  done < <(cd "$archive_root" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
}

# scan_for_archived_refs <scan-root> <archived-relative-path>... — greps
# EXACTLY scripts/, .copilot/, and AGENTS.md under <scan-root> (no other
# surface) for the literal `docs/evaluation/<archived-relative-path>` form.
# Prints offending file:line evidence to stdout and returns non-zero on any
# hit; returns 0 (silently) when none of the three surfaces exist under
# <scan-root>, or none of the archived paths are referenced.
scan_for_archived_refs() {
  local scan_root="$1"
  shift
  local -a targets=()
  [ -d "${scan_root}/scripts" ] && targets+=("${scan_root}/scripts")
  [ -d "${scan_root}/.copilot" ] && targets+=("${scan_root}/.copilot")
  [ -f "${scan_root}/AGENTS.md" ] && targets+=("${scan_root}/AGENTS.md")
  [ ${#targets[@]} -gt 0 ] || return 0

  local rel hit
  hit=0
  for rel in "$@"; do
    [ -n "$rel" ] || continue
    while IFS= read -r line; do
      printf '%s\n' "$line"
      hit=1
    done < <(grep -rnF -- "docs/evaluation/${rel}" "${targets[@]}" 2>/dev/null || true)
  done
  [ "$hit" -eq 0 ]
}

# --- Derive the live archived set (never a fixed list) -----------------------
archived_paths=()
while IFS= read -r rel; do
  archived_paths+=("$rel")
done < <(derive_archived_relative_paths "$ARCHIVE_DIR")

if [ ${#archived_paths[@]} -eq 0 ]; then
  fail "derive_archived_relative_paths found zero archived paths under ${ARCHIVE_DIR} (excluding the tombstone) — cannot self-test or scan"
fi

# --- Pick a real, currently PRESERVED docs/evaluation/ path for the negative
# fixture. Any top-level file still directly under docs/evaluation/ qualifies
# by construction (feature 1's own layout sensor pins that no archived
# relative path exists there); this still double-checks against the derived
# archived set defensively rather than assuming that invariant.
preserved_rel=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  case " ${archived_paths[*]-} " in
    *" ${candidate} "*) continue ;;
  esac
  preserved_rel="$candidate"
  break
done < <(find "$EVALUATION_DIR" -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)

if [ -z "$preserved_rel" ]; then
  fail "could not find a docs/evaluation/ top-level file outside the archived set — cannot build the negative self-test fixture"
fi

# --- Teeth proof: synthetic scratch trees, run before the real assertion ----
if [ ${#archived_paths[@]} -gt 0 ] && [ -n "$preserved_rel" ]; then
  SELF_TEST_TMP="$(mktemp -d)"
  trap 'rm -rf "${SELF_TEST_TMP}"' EXIT

  archived_rel="${archived_paths[0]}"

  # run_self_test <description> <scratch-scan-root> <want: fail|pass>
  run_self_test() {
    local desc="$1" scan_root="$2" want="$3"
    shift 3
    local output rc
    if output="$(scan_for_archived_refs "$scan_root" "$@")"; then
      rc=0
    else
      rc=$?
    fi
    case "$want" in
      fail)
        [ "$rc" -ne 0 ] \
          || fail "self-test '${desc}': scan_for_archived_refs must FAIL (a stale archived-path reference is present) but returned success"
        ;;
      pass)
        [ "$rc" -eq 0 ] \
          || fail "self-test '${desc}': scan_for_archived_refs must PASS (only a preserved path is present) but returned failure:
${output}"
        ;;
    esac
  }

  # (a) scripts/ names a real archived path -> FAIL
  fixture_a="${SELF_TEST_TMP}/positive-scripts"
  mkdir -p "${fixture_a}/scripts"
  printf '# see docs/evaluation/%s for background\n' "$archived_rel" >"${fixture_a}/scripts/note.sh"
  run_self_test "scripts/ file naming an archived path" "$fixture_a" fail "${archived_paths[@]}"

  # (b) .copilot/ names a real archived path -> FAIL
  fixture_b="${SELF_TEST_TMP}/positive-copilot"
  mkdir -p "${fixture_b}/.copilot"
  printf 'See docs/evaluation/%s for the retired doctrine.\n' "$archived_rel" >"${fixture_b}/.copilot/note.md"
  run_self_test ".copilot/ file naming an archived path" "$fixture_b" fail "${archived_paths[@]}"

  # (c) AGENTS.md names a real archived path -> FAIL
  fixture_c="${SELF_TEST_TMP}/positive-agents"
  mkdir -p "$fixture_c"
  printf '| Doc | [docs/evaluation/%s](docs/evaluation/%s) |\n' "$archived_rel" "$archived_rel" >"${fixture_c}/AGENTS.md"
  run_self_test "AGENTS.md naming an archived path" "$fixture_c" fail "${archived_paths[@]}"

  # (d) all three surfaces name only a real PRESERVED path -> PASS
  fixture_d="${SELF_TEST_TMP}/negative-preserved"
  mkdir -p "${fixture_d}/scripts" "${fixture_d}/.copilot"
  printf '# see docs/evaluation/%s for background\n' "$preserved_rel" >"${fixture_d}/scripts/note.sh"
  printf 'See docs/evaluation/%s for the live doctrine.\n' "$preserved_rel" >"${fixture_d}/.copilot/note.md"
  printf '| Doc | [docs/evaluation/%s](docs/evaluation/%s) |\n' "$preserved_rel" "$preserved_rel" >"${fixture_d}/AGENTS.md"
  run_self_test "preserved docs/evaluation path across all three scan surfaces" "$fixture_d" pass "${archived_paths[@]}"
fi

# --- Real assertion: this repo's actual scripts/, .copilot/, AGENTS.md ------
real_hits=""
if ! real_hits="$(scan_for_archived_refs "$ROOT" "${archived_paths[@]}")"; then
  fail "stale runtime/doctrine reference(s) to an archived docs/evaluation path found:
${real_hits}"
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d archived-evaluation-doc runtime-reference violation(s).\n' "$fails" >&2
  exit 1
fi
echo "no runtime script, .copilot doctrine file, or AGENTS.md references an archived docs/evaluation path"
