#!/usr/bin/env bash
# test_generator_self_check_checklist.sh — regression sensor for the generator's
# pre-handback self-check delivery checklist (issue #303, feature
# generator-self-check).
#
# Contract under test (PINNED HERE as the executable spec): under issue #303 the
# per-feature independent review is removed, so the GENERATOR must self-verify the
# product-quality general checks #1-#5 before handback. The generator subagent
# prompt (.copilot/agents/generator-subagent.agent.md) must carry a pre-handback
# SELF-CHECK DELIVERY CHECKLIST that:
#   1. Exists as its own clearly-labelled section (a "self-check" / "delivery
#      checklist" heading or list).
#   2. Names all five general quality checks: correctness, readability, tests,
#      error handling, and security.
#   3. Is framed as the generator's OWN self-verification / delivery checklist run
#      BEFORE handback — NOT an independent review verdict.
#
# The checklist is complementary to (and must stay distinct from) the four
# product-quality *blocking gates* already listed in the GREEN step, so this
# sensor also guards that the blocking-gate wording is not repurposed as the
# self-check.
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the generator prompt does not yet carry the self-check delivery checklist).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${ROOT}/.copilot/agents/generator-subagent.agent.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${AGENT}" ]; then
  printf 'FAIL: generator subagent prompt not found (%s)\n' "${AGENT}" >&2
  exit 1
fi

# 1. A self-check delivery checklist section must exist. Anchor on a heading or a
# clearly-labelled line that combines "self-check" with "delivery checklist".
if ! grep -qiE 'self-check.*delivery checklist|delivery checklist.*self-check|self-check delivery checklist' "${AGENT}"; then
  fail "generator prompt must carry a self-check delivery checklist section (labelled 'self-check' + 'delivery checklist')"
fi

# Extract the self-check region: from the first line naming the self-check
# delivery checklist down to the Output Format heading (its natural boundary).
# Anchor case-insensitively on both words so the "Self-Check" heading is caught.
block="$(sed -n '/[Ss]elf-[Cc]heck/,/^## Output Format/p' "${AGENT}")"

if [ -z "${block}" ]; then
  fail "could not locate the self-check delivery checklist block"
fi

# 2. All five general quality checks must be named inside the self-check block.
for check in 'correctness' 'readability' 'tests' 'error handling' 'security'; do
  if ! printf '%s\n' "${block}" | grep -qiE "${check}"; then
    fail "self-check checklist must name the general check '${check}'"
  fi
done

# 3. Framed as the generator's own self-verification run BEFORE handback, not an
# independent verdict.
printf '%s\n' "${block}" \
  | grep -qiE 'before handback|prior to handback|before the .*handback|self-verif' \
  || fail "self-check must be framed as self-verification the generator runs before handback"

printf '%s\n' "${block}" \
  | grep -qiE 'not an independent (review )?verdict|not a verdict|does not replace .*(independent )?review|complement' \
  || fail "self-check must be framed as a delivery checklist, NOT an independent review verdict"

# 3b. Guard distinctness: the self-check must not be presented as / conflated with
# the four product-quality blocking gates (those stay in the GREEN step).
if printf '%s\n' "${block}" | grep -qiE 'blocking gate'; then
  # Blocking gates may only be referenced to disclaim overlap ("distinct from",
  # "complement", "in addition to"); a bare re-listing here is a conflation.
  printf '%s\n' "${block}" \
    | grep -qiE 'distinct from .*blocking gate|complement.*blocking gate|in addition to .*blocking gate|separate from .*blocking gate' \
    || fail "self-check must stay distinct from the four product-quality blocking gates, not re-list them"
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d assertion(s) failed — generator self-check delivery checklist not satisfied.\n' \
    "${fails}" >&2
  exit 1
fi

printf 'PASS: generator prompt carries a pre-handback self-check delivery checklist covering checks #1-#5.\n'
