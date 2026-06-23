#!/usr/bin/env bash
# Regression sensor (issue #37): scripts/scaffold-language.sh must validate the
# profile name, emit shellcheck-clean skeleton assets from templates, be
# idempotent, refuse to clobber existing assets without --update, report the
# gates a profile adds to init.sh, and never touch the lifecycle scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${ROOT}/scripts/scaffold-language.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "${TMP_DIR}"; rm -f "${OUT}"' EXIT

# Hermetic repo seeded with the generator + the harness assets it reads/writes.
seed_repo() {
	local d="$1"
	mkdir -p "$d"
	cp -R "${ROOT}/scripts" "$d/scripts"
	cp -R "${ROOT}/profiles" "$d/profiles"
	cp -R "${ROOT}/.copilot" "$d/.copilot"
	( cd "$d" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed )
}

# --- Case (a): script shape + unknown/missing profile rejection (AC#1, AC#2) --
[ -x "$GEN" ] || { echo "case-a: $GEN not executable"; exit 1; }
bash -n "$GEN" || { echo "case-a: bash -n failed"; exit 1; }
if "$GEN" frob >"$OUT" 2>&1; then
	cat "$OUT"; echo "case-a: unknown profile must exit non-zero"; exit 1
fi
grep -qF "unknown profile 'frob'" "$OUT" || { cat "$OUT"; echo "case-a: missing unknown-profile message"; exit 1; }
if "$GEN" >"$OUT" 2>&1; then
	cat "$OUT"; echo "case-a: missing profile arg must exit non-zero"; exit 1
fi
grep -qi "usage" "$OUT" || { cat "$OUT"; echo "case-a: no usage on missing arg"; exit 1; }

# --- Case (b): known profile emits descriptor + instruction file (AC#1, AC#3) -
b="${TMP_DIR}/b"; seed_repo "$b"
( cd "$b" && ./scripts/scaffold-language.sh node --write >"$OUT" 2>&1 ) || { cat "$OUT"; echo "case-b: --write failed"; exit 1; }
desc="$b/profiles/node.profile.sh"
inst="$b/.copilot/instructions/node.instructions.md"
[ -f "$desc" ] || { echo "case-b: descriptor not created"; exit 1; }
[ -f "$inst" ] || { echo "case-b: instruction file not created"; exit 1; }
bash -n "$desc" || { echo "case-b: descriptor bash -n failed"; exit 1; }
shellcheck "$desc" || { echo "case-b: descriptor not shellcheck-clean"; exit 1; }
grep -qF "# shellcheck disable=SC2034" "$desc" || { echo "case-b: descriptor missing SC2034 disable"; exit 1; }
( set -e; cd "$b"
  # shellcheck disable=SC1091  # descriptor is generated at runtime by the generator under test
  . profiles/node.profile.sh
  [ "$PROFILE_ID" = "node" ] || { echo "case-b: PROFILE_ID != node"; exit 1; }
  [ "${#PROFILE_GATES[@]}" -gt 0 ] || { echo "case-b: empty PROFILE_GATES"; exit 1; } ) \
  || { echo "case-b: descriptor did not source cleanly"; exit 1; }
[ "$(head -1 "$inst")" = "---" ] || { echo "case-b: instruction frontmatter missing"; exit 1; }
grep -qE '^applyTo:' "$inst" || { echo "case-b: instruction missing applyTo"; exit 1; }

# --- Case (c): idempotency — second --write yields zero diff (AC#4) -----------
c="${TMP_DIR}/c"; seed_repo "$c"
( cd "$c" && ./scripts/scaffold-language.sh node --write >/dev/null 2>&1 \
  && git add -A && git -c user.email=t@t -c user.name=t commit -qm first \
  && ./scripts/scaffold-language.sh node --write >/dev/null 2>&1 )
[ -z "$(cd "$c" && git status --porcelain)" ] || { ( cd "$c" && git status --porcelain ); echo "case-c: second run produced a diff"; exit 1; }

# --- Case (d): no-clobber of an existing, differing asset (AC#5) --------------
d="${TMP_DIR}/d"; seed_repo "$d"
orig="$(cat "$d/profiles/python.profile.sh")"
( cd "$d" && ./scripts/scaffold-language.sh python --write >"$OUT" 2>&1 ) || { cat "$OUT"; echo "case-d: --write python failed"; exit 1; }
[ "$(cat "$d/profiles/python.profile.sh")" = "$orig" ] || { echo "case-d: existing python descriptor was clobbered by --write"; exit 1; }
grep -qF "pass --update" "$OUT" || { cat "$OUT"; echo "case-d: did not advise --update"; exit 1; }
( cd "$d" && ./scripts/scaffold-language.sh python --update >"$OUT" 2>&1 ) || { cat "$OUT"; echo "case-d: --update python failed"; exit 1; }
grep -qE '^@@|^\+\+\+ ' "$OUT" || { cat "$OUT"; echo "case-d: --update did not show a diff before overwriting"; exit 1; }

# --- Case (e): gate report honors the empty-slot rule (AC#6) ------------------
"$GEN" node >"$OUT" 2>&1 || { cat "$OUT"; echo "case-e: node dry run failed"; exit 1; }
grep -qF "Gates this profile adds to init.sh: format_check lint typecheck test" "$OUT" \
  || { cat "$OUT"; echo "case-e: wrong node gate report"; exit 1; }
"$GEN" go >"$OUT" 2>&1 || { cat "$OUT"; echo "case-e: go dry run failed"; exit 1; }
grep -qF "Gates this profile adds to init.sh: format_check lint test" "$OUT" \
  || { cat "$OUT"; echo "case-e: wrong go gate report"; exit 1; }
grep -q "typecheck" "$OUT" && { cat "$OUT"; echo "case-e: go must not declare a typecheck gate"; exit 1; }

# --- Case (f): lifecycle scripts left untouched (AC#7) ------------------------
f="${TMP_DIR}/f"; seed_repo "$f"
( cd "$f" && ./scripts/scaffold-language.sh node --write >/dev/null 2>&1 )
( cd "$f" && git diff --quiet -- \
  scripts/issue-lib.sh scripts/start-issue.sh scripts/check-feature-list.sh \
  scripts/review-gate.sh scripts/create-pr.sh scripts/merge-pr.sh scripts/finish-issue.sh ) \
  || { echo "case-f: generator modified a lifecycle script"; exit 1; }

printf 'scaffold-language generator sensor passed\n'
