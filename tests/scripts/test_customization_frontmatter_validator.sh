#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${ROOT}/tests/evals/bin/validate-customization-frontmatter.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$VALIDATOR" ] \
  || hard_fail "shared customization frontmatter validator not found: ${VALIDATOR}"

make_skill() {
  local directory="$1"
  shift
  mkdir -p "${TMP_DIR}/skills/${directory}"
  printf '%s\n' "$@" >"${TMP_DIR}/skills/${directory}/SKILL.md"
}

make_agent() {
  local filename="$1"
  shift
  mkdir -p "${TMP_DIR}/agents"
  printf '%s\n' "$@" >"${TMP_DIR}/agents/${filename}.agent.md"
}

OUT="${TMP_DIR}/out.txt"
ERR="${TMP_DIR}/err.txt"
run_validator() {
  local rc=0
  bash "$VALIDATOR" "$@" >"$OUT" 2>"$ERR" || rc=$?
  printf '%s' "$rc"
}

assert_valid() {
  local label="$1"
  shift
  local rc
  rc="$(run_validator "$@")"
  [ "$rc" = "0" ] \
    || fail "${label}: expected valid input, got exit ${rc} (stderr: $(<"$ERR"))"
}

assert_invalid() {
  local label="$1"
  local path="$2"
  local reason="$3"
  local rc
  rc="$(run_validator "$path")"
  [ "$rc" != "0" ] \
    || fail "${label}: expected rejection reason ${reason}, got exit 0"
  grep -Fq -- "invalid_frontmatter: ${reason}:" "$ERR" \
    || fail "${label}: expected stable reason ${reason}, got: $(<"$ERR")"
}

max_name="$(awk 'BEGIN { for (i = 0; i < 64; i++) printf "a" }')"
long_description="$(awk 'BEGIN { for (i = 0; i < 1025; i++) printf "x" }')"

make_skill "a" \
  '---' \
  'name: a' \
  'description: "Review: focused changes"' \
  '---'
make_skill "$max_name" \
  '---' \
  "name: ${max_name}" \
  'description: Boundary-length skill name' \
  '---'
make_agent "unnamed" \
  '---' \
  'description: Agent names are optional' \
  '---'
make_agent "unconstrained-name" \
  '---' \
  'name: Agent_Name/Is-Not-A-Skill-Identity' \
  'description: Agent names do not use skill identity rules' \
  '---'
make_agent "quoted-indicator" \
  '---' \
  'description: "|"' \
  '---'
make_agent "quoted-commented-indicator" \
  '---' \
  'description: "| # retained"' \
  '---'
make_agent "double-quoted-hash" \
  '---' \
  'description: "value # retained"' \
  '---'
make_agent "single-quoted-hash" \
  '---' \
  "description: 'value # retained'" \
  '---'
make_agent "plain-trailing-comment" \
  '---' \
  'description: value # ignored comment' \
  '---'

assert_valid "explicit valid skills and agent name variants" \
  "${TMP_DIR}/skills/a/SKILL.md" \
  "${TMP_DIR}/skills/${max_name}/SKILL.md" \
  "${TMP_DIR}/agents/unnamed.agent.md" \
  "${TMP_DIR}/agents/unconstrained-name.agent.md" \
  "${TMP_DIR}/agents/quoted-indicator.agent.md" \
  "${TMP_DIR}/agents/quoted-commented-indicator.agent.md" \
  "${TMP_DIR}/agents/double-quoted-hash.agent.md" \
  "${TMP_DIR}/agents/single-quoted-hash.agent.md" \
  "${TMP_DIR}/agents/plain-trailing-comment.agent.md"

make_skill "missing-frontmatter" \
  '# Missing both fences and required fields'
make_skill "unterminated-frontmatter" \
  '---' \
  $'\tname: unterminated-frontmatter'
make_skill "tab-indentation" \
  '---' \
  $'\tname: tab-indentation' \
  '---'
make_skill "missing-name" \
  '---' \
  'description:' \
  '---'
make_skill "namespace-prefix" \
  '---' \
  'name: acme/namespace-prefix' \
  '---'
make_skill "invalid-name" \
  '---' \
  'name: Invalid_Name' \
  '---'
make_skill "expected-directory" \
  '---' \
  'name: different-name' \
  '---'
make_skill "missing-description" \
  '---' \
  'name: missing-description' \
  'description: ""' \
  '---'
make_skill "block-scalar-description" \
  '---' \
  'name: block-scalar-description' \
  'description: |' \
  '  Unsupported multiline content' \
  '---'
make_skill "description-too-long" \
  '---' \
  'name: description-too-long' \
  "description: ${long_description}" \
  '---'
make_agent "missing-description" \
  '---' \
  'name: optional-agent-name' \
  'description: ""' \
  '---'
make_agent "comment-only-description" \
  '---' \
  'description: # no value' \
  '---'
make_agent "quoted-empty-comment-description" \
  '---' \
  'description: "" # empty value' \
  '---'
make_agent "description-too-long" \
  '---' \
  "description: ${long_description}" \
  '---'

assert_invalid "missing frontmatter precedes missing fields" \
  "${TMP_DIR}/skills/missing-frontmatter/SKILL.md" "missing_frontmatter"
assert_invalid "unterminated frontmatter precedes tabs" \
  "${TMP_DIR}/skills/unterminated-frontmatter/SKILL.md" "unterminated_frontmatter"
assert_invalid "tab indentation precedes missing fields" \
  "${TMP_DIR}/skills/tab-indentation/SKILL.md" "tab_indentation"
assert_invalid "skill name is required before description" \
  "${TMP_DIR}/skills/missing-name/SKILL.md" "missing_name"
assert_invalid "namespace prefix precedes generic invalid name" \
  "${TMP_DIR}/skills/namespace-prefix/SKILL.md" "namespace_prefix"
assert_invalid "invalid skill name precedes description" \
  "${TMP_DIR}/skills/invalid-name/SKILL.md" "invalid_name"
assert_invalid "skill name must match its directory before description" \
  "${TMP_DIR}/skills/expected-directory/SKILL.md" "name_mismatch"
assert_invalid "description is required and nonempty" \
  "${TMP_DIR}/skills/missing-description/SKILL.md" "missing_description"
assert_invalid "description must use a single-line scalar" \
  "${TMP_DIR}/skills/block-scalar-description/SKILL.md" "missing_description"

block_scalar_variants=('>' '|-' '|+' '|2' '>-' '>+' '>2' '|2-' '>2+')
variant_number=0
for block_scalar_variant in "${block_scalar_variants[@]}"; do
  variant_number=$((variant_number + 1))
  variant_name="block-scalar-variant-${variant_number}"
  make_skill "$variant_name" \
    '---' \
    "name: ${variant_name}" \
    "description: ${block_scalar_variant}" \
    '  Unsupported multiline content' \
    '---'
  assert_invalid "description block scalar variant ${block_scalar_variant}" \
    "${TMP_DIR}/skills/${variant_name}/SKILL.md" "missing_description"
done

commented_block_scalar_variants=('| # multiline' '> # multiline' '|- # multiline' '>2 # multiline')
for block_scalar_variant in "${commented_block_scalar_variants[@]}"; do
  variant_number=$((variant_number + 1))
  variant_name="block-scalar-variant-${variant_number}"
  make_skill "$variant_name" \
    '---' \
    "name: ${variant_name}" \
    "description: ${block_scalar_variant}" \
    '  Unsupported multiline content' \
    '---'
  assert_invalid "description commented block scalar variant ${block_scalar_variant}" \
    "${TMP_DIR}/skills/${variant_name}/SKILL.md" "missing_description"
done

assert_invalid "description is limited to 1024 characters" \
  "${TMP_DIR}/skills/description-too-long/SKILL.md" "description_too_long"
assert_invalid "agent description is required and nonempty" \
  "${TMP_DIR}/agents/missing-description.agent.md" "missing_description"
assert_invalid "inline comment is not a description value" \
  "${TMP_DIR}/agents/comment-only-description.agent.md" "missing_description"
assert_invalid "quoted empty description remains empty before an inline comment" \
  "${TMP_DIR}/agents/quoted-empty-comment-description.agent.md" "missing_description"
assert_invalid "agent description is limited to 1024 characters" \
  "${TMP_DIR}/agents/description-too-long.agent.md" "description_too_long"

assert_valid "no-argument discovery accepts checked-in skills and agents"

if [ "$fails" -ne 0 ]; then
  printf 'FAIL: %d customization frontmatter assertion(s) regressed\n' "$fails" >&2
  exit 1
fi

printf 'PASS: customization frontmatter validator honors all stable reasons and valid boundaries\n'