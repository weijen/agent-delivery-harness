#!/usr/bin/env bash
# Regression sensor (issue #76): scripts/install-harness.sh must copy the REAL
# harness assets verbatim into a target directory, default to a dry run, apply
# with --write, refuse to clobber a differing target file without --update (while
# printing the diff), and never touch the target project's own non-harness files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "${TMP_DIR}"; rm -f "${OUT}"' EXIT

# Representative assets that MUST land in a target install (one per asset group).
REQUIRED_FILES=(
	scripts/install-harness.sh
	scripts/init.sh
	scripts/issue-lib.sh
	profiles/python.profile.sh
	tests/scripts/test_install_harness.sh
	tests/meta/test_role_separation.sh
	.copilot/instructions/harness.instructions.md
	.copilot/instructions/python.instructions.md
	.copilot/agents/planning-subagent.agent.md
	.github/workflows/harness-smoke.yml
	docs/HARNESS.md
	docs/getting-started.md
	docs/multi-language-profiles.md
	docs/harness-contract.yml
)

# --- Case (a): script shape (executable, parses, shellcheck-clean) ------------
[ -x "$INSTALL" ] || { echo "case-a: $INSTALL not executable"; exit 1; }
bash -n "$INSTALL" || { echo "case-a: bash -n failed"; exit 1; }
if command -v shellcheck >/dev/null 2>&1; then
	shellcheck "$INSTALL" || { echo "case-a: not shellcheck-clean"; exit 1; }
fi
# Missing target dir argument must fail with usage.
if "$INSTALL" >"$OUT" 2>&1; then
	cat "$OUT"; echo "case-a: missing target arg must exit non-zero"; exit 1
fi
grep -qi "usage" "$OUT" || { cat "$OUT"; echo "case-a: no usage on missing arg"; exit 1; }

# --- Case (b): dry run is the default and writes nothing (AC: dry run default) -
b="${TMP_DIR}/b"; mkdir -p "$b"
"$INSTALL" "$b" >"$OUT" 2>&1 || { cat "$OUT"; echo "case-b: dry run failed"; exit 1; }
grep -qF "would create" "$OUT" || { cat "$OUT"; echo "case-b: dry run did not report would-create"; exit 1; }
if [ -n "$(find "$b" -type f)" ]; then
	echo "case-b: dry run wrote files into the target"; exit 1
fi

# --- Case (c): --write installs the full harness verbatim (AC: empty dir copy) -
c="${TMP_DIR}/c"; mkdir -p "$c"
"$INSTALL" "$c" --write >"$OUT" 2>&1 || { cat "$OUT"; echo "case-c: --write failed"; exit 1; }
for rel in "${REQUIRED_FILES[@]}"; do
	[ -f "$c/$rel" ] || { echo "case-c: expected asset not installed: $rel"; exit 1; }
done
# Files are copied verbatim (byte-for-byte), not regenerated/skeletonised.
for rel in "${REQUIRED_FILES[@]}"; do
	cmp -s "$ROOT/$rel" "$c/$rel" || { echo "case-c: installed asset differs from source: $rel"; exit 1; }
done
# The REAL subagent file, not a skeleton TODO placeholder.
grep -qiF "skeleton" "$c/.copilot/agents/planning-subagent.agent.md" \
	&& { echo "case-c: agent file looks like a skeleton, expected the real asset"; exit 1; }
# __pycache__ / compiled artifacts must not be dragged along.
if find "$c" -name '*.pyc' -o -name '__pycache__' | grep -q .; then
	echo "case-c: copied python bytecode/__pycache__ artifacts"; exit 1
fi

# --- Case (d): idempotency — a second --write is a clean no-op ----------------
"$INSTALL" "$c" --write >"$OUT" 2>&1 || { cat "$OUT"; echo "case-d: second --write failed"; exit 1; }
grep -qF "up to date" "$OUT" || { cat "$OUT"; echo "case-d: second --write did not report up-to-date"; exit 1; }
for rel in "${REQUIRED_FILES[@]}"; do
	cmp -s "$ROOT/$rel" "$c/$rel" || { echo "case-d: idempotent run changed an asset: $rel"; exit 1; }
done

# --- Case (e): no-clobber of a differing harness file without --update --------
e="${TMP_DIR}/e"; mkdir -p "$e/scripts" "$e/src"
printf 'PROJECT LOCAL EDIT — do not overwrite\n' >"$e/scripts/init.sh"
sentinel="$e/scripts/init.sh"
sentinel_before="$(cat "$sentinel")"
# A non-harness project file that must never be touched.
printf 'print("hello")\n' >"$e/src/app.py"
app_before="$(cat "$e/src/app.py")"
if "$INSTALL" "$e" --write >"$OUT" 2>&1; then
	cat "$OUT"; echo "case-e: --write over a differing harness file must exit non-zero"; exit 1
fi
[ "$(cat "$sentinel")" = "$sentinel_before" ] || { echo "case-e: differing harness file was clobbered by --write"; exit 1; }
grep -qF -- "--update" "$OUT" || { cat "$OUT"; echo "case-e: did not advise --update"; exit 1; }
grep -qE '^@@|^\+\+\+ |^--- ' "$OUT" || { cat "$OUT"; echo "case-e: did not print a diff for the differing file"; exit 1; }
# The project's own file is left untouched.
[ "$(cat "$e/src/app.py")" = "$app_before" ] || { echo "case-e: a non-harness project file was modified"; exit 1; }
# New harness files are still installed alongside the refused one.
[ -f "$e/profiles/python.profile.sh" ] || { echo "case-e: new assets were not installed when one file was refused"; exit 1; }

# --- Case (f): --update overwrites the differing file after showing the diff ---
"$INSTALL" "$e" --update >"$OUT" 2>&1 || { cat "$OUT"; echo "case-f: --update failed"; exit 1; }
grep -qE '^@@|^\+\+\+ |^--- ' "$OUT" || { cat "$OUT"; echo "case-f: --update did not show a diff before overwriting"; exit 1; }
cmp -s "$ROOT/scripts/init.sh" "$sentinel" || { echo "case-f: --update did not bring init.sh up to date"; exit 1; }
[ "$(cat "$e/src/app.py")" = "$app_before" ] || { echo "case-f: --update touched a non-harness project file"; exit 1; }

printf 'install-harness sensor passed\n'
