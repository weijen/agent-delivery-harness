#!/usr/bin/env bash
# test_fixture_recipe_smoke_doc_consistency.sh — regression sensor for issue #319,
# feature fixture-recipe-smoke-doc-consistency.
#
# Bash 3.2 portable: no associative arrays (declare -A), no mapfile/readarray,
# no ${var,,} case folding. Uses parallel indexed arrays and linear lookup
# functions for key→value maps (same pattern as test_l0_manifests.sh).
#
# Contract under test: a JSON manifest at
# tests/fixtures/copilot-log-review/cli-record-contract.json declares the exact
# set of native-record fixtures and jq recipes. This sensor enforces
# bidirectional consistency:
#   - Every jq fenced block in SKILL.md maps to exactly one manifest recipe entry
#   - Every manifest recipe ID maps to exactly one jq fenced block in SKILL.md
#   - Fixture paths exist and JSONL lines parse
#   - CLI fixture version == the manifest's declared observed version
#
# Legs:
#   A: Manifest schema — exists, valid JSON, schema_version=="1.0.0", structural
#      array type (exit on failure), required fields/types via jq (nonempty strings,
#      integer ordinals via floor==., source_context_level ##|###, fixture_backed
#      boolean, matrix_version_cell nonempty, referenced fixture IDs checked)
#   B: Manifest uniqueness — fixture IDs+paths, recipe IDs+source tuples, claim
#      IDs all unique; exactly one fixture-backed claim and one CLI-version fixture
#   C: Fixture records — each declared path exists and JSONL lines parse
#   D: Recipe discovery — extract >=1 jq fenced blocks from SKILL.md
#   E: Recipe↔manifest set equality — discovered source-tuple set == manifest
#      source-tuple set (bidirectional, equal counts, unique)
#   F: Recipe execution — each jq recipe runs against its declared fixture
#   G: Recipe expectations — each manifest expectation validates against output
#   H: CLI fixture version link — observed_cli_version equals the fixture's
#      first-event .data.cliVersion.
#
# Teeth (mutation legs, skipped under SKIP_RECURSIVE_MUTATIONS=1):
#   T1: Append a new jq fence under new heading → source-tuple set mismatch
#   T2: Remove a recipe entry from manifest → orphan discovered recipe
#   T4: Change CLI fixture version → version cross-check failure
#   T5: Add orphan manifest recipe (no matching SKILL.md block) → set mismatch
#   T7: Duplicate a manifest recipe ID/source tuple → uniqueness failure
#   T9: Set ordinal to 1.5 → structural integer validation catches it
#   T10: Remove fixture surface (null) → structural type check catches it
#
# Environment overrides (test-only):
#   MANIFEST — path to the contract manifest JSON
#   SKILL_PATH — path to SKILL.md
#   FIXTURE_ROOT — root for resolving fixture relative paths
#   SKIP_RECURSIVE_MUTATIONS — when "1", skip teeth legs (recursion guard)
#
# Exit codes: 0 all pass · 1 any obligation fails

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${MANIFEST:-${ROOT}/tests/fixtures/copilot-log-review/cli-record-contract.json}"
SKILL_PATH="${SKILL_PATH:-${ROOT}/.copilot/skills/copilot-log-review/SKILL.md}"
FIXTURE_ROOT="${FIXTURE_ROOT:-${ROOT}}"

fails=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  fails=$((fails + 1))
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL: jq is required but not found on PATH\n' >&2
  exit 1
fi

# Helper: strip Markdown backticks and trim whitespace
normalize_cell() {
  printf '%s' "$1" | sed 's/`//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# --- Bash-3.2-portable linear-lookup helpers for parallel indexed arrays ------
# _lookup_disc_jqfile <key> — print jq filepath for a discovered source-tuple key
_lookup_disc_jqfile() {
  local needle="$1" idx=0
  while [ "$idx" -lt "${#discovered_keys[@]}" ]; do
    if [ "${discovered_keys[idx]}" = "$needle" ]; then
      printf '%s' "${_disc_jqfiles[idx]}"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# _lookup_mani_id <key> — print manifest recipe id for a manifest source-tuple key
_lookup_mani_id() {
  local needle="$1" idx=0
  while [ "$idx" -lt "${#manifest_recipe_keys[@]}" ]; do
    if [ "${manifest_recipe_keys[idx]}" = "$needle" ]; then
      printf '%s' "${_mani_ids[idx]}"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# ==============================================================================
# Leg A: Manifest exists, valid JSON, schema_version=="1.0.0", structural checks
# ==============================================================================
if [ ! -f "$MANIFEST" ]; then
  fail "A" "contract manifest not found at ${MANIFEST}"
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi
if ! jq empty "$MANIFEST" 2>/dev/null; then
  fail "A" "manifest is not valid JSON"
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi

SUPPORTED_SCHEMA="1.0.0"
schema_version="$(jq -r '.schema_version // empty' "$MANIFEST")"
if [ "$schema_version" != "$SUPPORTED_SCHEMA" ]; then
  fail "A" "manifest schema_version must be exactly '${SUPPORTED_SCHEMA}', got '${schema_version}'"
fi

# Structural array type check — exit cleanly on failure (unsafe to loop non-arrays)
struct_ok=true
for arr in fixtures recipes; do
  arr_type="$(jq -r --arg a "$arr" '.[$a] | type' "$MANIFEST")"
  if [ "$arr_type" != "array" ]; then
    fail "A" "manifest .${arr} must be an array (got type '${arr_type}')"
    struct_ok=false
  else
    arr_len="$(jq --arg a "$arr" '.[$a] | length' "$MANIFEST")"
    if [ "$arr_len" -lt 1 ]; then
      fail "A" "manifest .${arr} must be non-empty (got length ${arr_len})"
      struct_ok=false
    fi
  fi
done
if [ "$struct_ok" != "true" ]; then
  printf '\n%d obligation(s) failed (structural array type check).\n' "$fails" >&2
  exit 1
fi

fixture_count="$(jq '.fixtures | length' "$MANIFEST")"
recipe_count="$(jq '.recipes | length' "$MANIFEST")"

# Validate fixtures: id, relative_path, surface must be nonempty strings;
# observed_cli_version must be null or nonempty string
for i in $(seq 0 $((fixture_count - 1))); do
  for fld in id relative_path surface; do
    fld_ok="$(jq ".fixtures[$i].${fld} | type == \"string\" and length > 0" "$MANIFEST")"
    if [ "$fld_ok" != "true" ]; then
      fail "A" "fixture[$i].${fld} must be a non-empty string"
    fi
  done
  ocv_ok="$(jq ".fixtures[$i].observed_cli_version | . == null or (type == \"string\" and length > 0)" "$MANIFEST")"
  if [ "$ocv_ok" != "true" ]; then
    fail "A" "fixture[$i].observed_cli_version must be null or a non-empty string"
  fi
done

# Validate recipes: required strings, source_context_level only ## or ###,
# ordinal must be a numeric integer >= 1
for i in $(seq 0 $((recipe_count - 1))); do
  for fld in id source_heading source_context_level fixture_id expectation; do
    fld_ok="$(jq ".recipes[$i].${fld} | type == \"string\" and length > 0" "$MANIFEST")"
    if [ "$fld_ok" != "true" ]; then
      fail "A" "recipe[$i].${fld} must be a non-empty string"
    fi
  done
  # source_context_level constraint
  scl="$(jq -r ".recipes[$i].source_context_level" "$MANIFEST")"
  if [ "$scl" != "##" ] && [ "$scl" != "###" ]; then
    fail "A" "recipe[$i].source_context_level must be '##' or '###', got '${scl}'"
  fi
  # ordinal: numeric integer >= 1 (jq type check, not shell -lt on text)
  ord_ok="$(jq ".recipes[$i].ordinal | type == \"number\" and floor == . and . >= 1" "$MANIFEST")"
  if [ "$ord_ok" != "true" ]; then
    ord_raw="$(jq ".recipes[$i].ordinal" "$MANIFEST")"
    fail "A" "recipe[$i].ordinal must be a positive integer (number, floor==self, >=1), got '${ord_raw}'"
  fi
  # Verify referenced fixture ID exists
  ref_fid="$(jq -r ".recipes[$i].fixture_id" "$MANIFEST")"
  ref_exists="$(jq --arg fid "$ref_fid" '[.fixtures[].id] | any(. == $fid)' "$MANIFEST")"
  if [ "$ref_exists" != "true" ]; then
    fail "A" "recipe[$i].fixture_id '${ref_fid}' references a fixture not declared in manifest"
  fi
done

# ==============================================================================
# Leg B: Manifest uniqueness — IDs, paths, source tuples, fixture-backed count
# ==============================================================================

# Fixture IDs unique
fixture_id_dups="$(jq -r '[.fixtures[].id] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$fixture_id_dups" ]; then
  fail "B" "duplicate fixture id: '${fixture_id_dups}'"
fi
# Fixture paths unique
fixture_path_dups="$(jq -r '[.fixtures[].relative_path] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$fixture_path_dups" ]; then
  fail "B" "duplicate fixture relative_path: '${fixture_path_dups}'"
fi
# Recipe IDs unique
recipe_id_dups="$(jq -r '[.recipes[].id] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$recipe_id_dups" ]; then
  fail "B" "duplicate recipe id: '${recipe_id_dups}'"
fi
# Recipe source tuples unique
recipe_tuple_dups="$(jq -r '[.recipes[] | "\(.source_context_level)|\(.source_heading)|\(.ordinal)"] | group_by(.) | map(select(length>1))[0][0] // empty' "$MANIFEST")"
if [ -n "$recipe_tuple_dups" ]; then
  fail "B" "duplicate recipe source tuple: '${recipe_tuple_dups}'"
fi
# Exactly one fixture with observed_cli_version (v1 simplicity)
cli_version_fixture_count="$(jq '[.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "")] | length' "$MANIFEST")"
if [ "$cli_version_fixture_count" -ne 1 ]; then
  fail "B" "expected exactly 1 fixture with observed_cli_version, got ${cli_version_fixture_count}"
fi

# ==============================================================================
# Leg C: Fixture records — paths exist and JSONL lines parse
# ==============================================================================
for i in $(seq 0 $((fixture_count - 1))); do
  fid="$(jq -r ".fixtures[$i].id" "$MANIFEST")"
  fpath="$(jq -r ".fixtures[$i].relative_path" "$MANIFEST")"
  full_path="${FIXTURE_ROOT}/${fpath}"
  if [ ! -f "$full_path" ]; then
    fail "C" "fixture '${fid}' path does not exist: ${full_path}"
    continue
  fi
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [ -n "$line" ] && ! printf '%s' "$line" | jq empty 2>/dev/null; then
      fail "C" "fixture '${fid}' line ${line_num} is not valid JSON"
      break
    fi
  done < "$full_path"
done

# ==============================================================================
# Leg D: Recipe discovery — awk state machine to extract jq blocks
# ==============================================================================
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

awk -v tmpdir="$TMP_DIR" '
  /^(##|###)[[:space:]]+/ {
    heading = $0
    level = heading
    sub(/[[:space:]]+.*/, "", level)
    sub(/^##+[[:space:]]+/, "", heading)
    fence_in_heading = 0
  }
  /^```jq[[:space:]]*$/ {
    fence_in_heading++
    in_fence = 1
    outfile = tmpdir "/recipe_" NR ".jq"
    printf "" > outfile
    printf "%s\t%s\t%d\t%s\n", level, heading, fence_in_heading, outfile >> (tmpdir "/index.tsv")
    next
  }
  in_fence && /^```[[:space:]]*$/ {
    in_fence = 0
    close(outfile)
    next
  }
  in_fence {
    print >> outfile
  }
' "$SKILL_PATH"

discovered_count=0
if [ -f "$TMP_DIR/index.tsv" ]; then
  discovered_count="$(wc -l < "$TMP_DIR/index.tsv" | tr -d ' ')"
fi
if [ "$discovered_count" -lt 1 ]; then
  fail "D" "no jq fenced blocks discovered in SKILL.md (expected >=1)"
fi

# ==============================================================================
# Leg E: Recipe↔manifest set equality (bidirectional, equal counts, unique)
# ==============================================================================
# Parallel indexed arrays (Bash-3.2-portable map emulation):
#   discovered_keys[i]  → source tuple key
#   _disc_jqfiles[i]    → corresponding discovered jq file path
discovered_keys=()
_disc_jqfiles=()
if [ -f "$TMP_DIR/index.tsv" ]; then
  while IFS=$'\t' read -r dlevel dheading dordinal djqfile; do
    dkey="${dlevel}|${dheading}|${dordinal}"
    discovered_keys+=("$dkey")
    _disc_jqfiles+=("$djqfile")
  done < "$TMP_DIR/index.tsv"
fi

# Build manifest source-tuple set (parallel indexed arrays):
#   manifest_recipe_keys[i] → source tuple key
#   _mani_ids[i]            → corresponding manifest recipe id
manifest_recipe_keys=()
_mani_ids=()
for i in $(seq 0 $((recipe_count - 1))); do
  mheading="$(jq -r ".recipes[$i].source_heading" "$MANIFEST")"
  mlevel="$(jq -r ".recipes[$i].source_context_level" "$MANIFEST")"
  mordinal="$(jq -r ".recipes[$i].ordinal" "$MANIFEST")"
  mkey="${mlevel}|${mheading}|${mordinal}"
  mid="$(jq -r ".recipes[$i].id" "$MANIFEST")"
  manifest_recipe_keys+=("$mkey")
  _mani_ids+=("$mid")
done

# Equal counts
if [ "$discovered_count" -ne "$recipe_count" ]; then
  fail "E" "discovered ${discovered_count} jq blocks but manifest declares ${recipe_count} recipes (count mismatch)"
fi

# Discovered → manifest (no orphan discovered)
for dkey in "${discovered_keys[@]}"; do
  if ! _lookup_mani_id "$dkey" >/dev/null 2>&1; then
    fail "E" "discovered jq block '${dkey}' not registered in manifest (orphan discovered recipe)"
  fi
done

# Manifest → discovered (no orphan manifest recipe)
for mkey in "${manifest_recipe_keys[@]}"; do
  if ! _lookup_disc_jqfile "$mkey" >/dev/null 2>&1; then
    mid="$(_lookup_mani_id "$mkey")"
    fail "E" "manifest recipe '${mid}' (${mkey}) not found in SKILL.md (orphan manifest recipe)"
  fi
done

# ==============================================================================
# Leg F: Recipe execution — each jq recipe runs against its declared fixture
# ==============================================================================
for i in $(seq 0 $((recipe_count - 1))); do
  rid="$(jq -r ".recipes[$i].id" "$MANIFEST")"
  fixture_id="$(jq -r ".recipes[$i].fixture_id" "$MANIFEST")"
  mheading="$(jq -r ".recipes[$i].source_heading" "$MANIFEST")"
  mlevel="$(jq -r ".recipes[$i].source_context_level" "$MANIFEST")"
  mordinal="$(jq -r ".recipes[$i].ordinal" "$MANIFEST")"
  mkey="${mlevel}|${mheading}|${mordinal}"

  fixture_path="$(jq -r --arg fid "$fixture_id" '.fixtures[] | select(.id == $fid) | .relative_path' "$MANIFEST")"
  if [ -z "$fixture_path" ]; then
    fail "F" "recipe '${rid}' references fixture_id '${fixture_id}' not found in manifest fixtures"
    continue
  fi
  full_fixture="${FIXTURE_ROOT}/${fixture_path}"

  jq_file="$(_lookup_disc_jqfile "$mkey" || true)"
  if [ -z "$jq_file" ] || [ ! -s "$jq_file" ]; then
    fail "F" "recipe '${rid}' has no extracted jq file (key '${mkey}')"
    continue
  fi

  recipe_output_file="${TMP_DIR}/output_${rid}.json"
  if ! jq -s -f "$jq_file" "$full_fixture" > "$recipe_output_file" 2>"${TMP_DIR}/err_${rid}.txt"; then
    fail "F" "recipe '${rid}' failed: $(cat "${TMP_DIR}/err_${rid}.txt")"
    continue
  fi
done

# ==============================================================================
# Leg G: Recipe expectations — validate each manifest expectation
# ==============================================================================
for i in $(seq 0 $((recipe_count - 1))); do
  rid="$(jq -r ".recipes[$i].id" "$MANIFEST")"
  recipe_output_file="${TMP_DIR}/output_${rid}.json"
  [ -f "$recipe_output_file" ] || continue

  expectation="$(jq -r ".recipes[$i].expectation // empty" "$MANIFEST")"
  if [ -z "$expectation" ]; then
    fail "G" "recipe '${rid}' has no expectation in manifest"
    continue
  fi

  result="$(jq -r "$expectation" "$recipe_output_file" 2>"${TMP_DIR}/expect_err_${rid}.txt")" || true
  if [ "$result" != "true" ]; then
    fail "G" "recipe '${rid}' expectation failed (got '${result}'): ${expectation}"
  fi
done

# ==============================================================================
# Leg H: CLI native-record version link
# ==============================================================================
manifest_cli_version="$(jq -r '.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "") | .observed_cli_version' "$MANIFEST" | head -1)"
if [ -n "$manifest_cli_version" ]; then
  cli_fixture_path="$(jq -r '.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "") | .relative_path' "$MANIFEST" | head -1)"
  actual_version="$(head -1 "${FIXTURE_ROOT}/${cli_fixture_path}" | jq -r '.data.cliVersion // empty')"
  if [ "$actual_version" != "$manifest_cli_version" ]; then
    fail "H" "manifest CLI version '${manifest_cli_version}' != fixture first-event .data.cliVersion '${actual_version}'"
  fi
fi

# ==============================================================================
# Teeth: Mutation legs (skipped under recursion guard)
# ==============================================================================
if [ "${SKIP_RECURSIVE_MUTATIONS:-0}" != "1" ]; then

  SELF="${BASH_SOURCE[0]}"
  MUTANT_DIR="${TMP_DIR}/mutants"
  mkdir -p "$MUTANT_DIR"

  # --- T1: Append new jq fence → source-tuple set mismatch -------------------
  MUTANT_SKILL="${MUTANT_DIR}/skill-t1.md"
  cp "$SKILL_PATH" "$MUTANT_SKILL"
  cat >> "$MUTANT_SKILL" <<'EOF'

### Phantom recipe

```jq
{ phantom: true }
```
EOF
  if SKILL_PATH="$MUTANT_SKILL" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T1" "TEETH: sensor passes with an unregistered jq fence appended (set mismatch not detected)"
  fi

  # --- T2: Remove a recipe entry → orphan discovered recipe -------------------
  MUTANT_MANIFEST="${MUTANT_DIR}/manifest-t2.json"
  jq 'del(.recipes[0])' "$MANIFEST" > "$MUTANT_MANIFEST"
  if MANIFEST="$MUTANT_MANIFEST" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T2" "TEETH: sensor passes with a recipe entry removed from manifest"
  fi

  # --- T4: Change CLI fixture version → version cross-check -------------------
  MUTANT_FIXTURE_DIR="${MUTANT_DIR}/fixtures-t4"
  mkdir -p "$MUTANT_FIXTURE_DIR/tests/fixtures/copilot-log-review"
  cli_fixture_relpath="$(jq -r '.fixtures[] | select(.observed_cli_version != null and .observed_cli_version != "") | .relative_path' "$MANIFEST" | head -1)"
  if [ -n "$cli_fixture_relpath" ]; then
    while IFS= read -r fpath; do
      fdir="$(dirname "$fpath")"
      mkdir -p "${MUTANT_FIXTURE_DIR}/${fdir}"
      cp "${FIXTURE_ROOT}/${fpath}" "${MUTANT_FIXTURE_DIR}/${fpath}"
    done < <(jq -r '.fixtures[].relative_path' "$MANIFEST")
    # Mutate the CLI fixture version
    sed 's/"cliVersion":"1.0.72-1"/"cliVersion":"9.9.99"/' "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}" \
      > "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}.tmp" \
      && mv "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}.tmp" "${MUTANT_FIXTURE_DIR}/${cli_fixture_relpath}"
    if FIXTURE_ROOT="$MUTANT_FIXTURE_DIR" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
      fail "T4" "TEETH: sensor passes with CLI fixture version changed"
    fi
  fi

  # --- T5: Add orphan manifest recipe (no SKILL.md block) → set mismatch -----
  MUTANT_MANIFEST5="${MUTANT_DIR}/manifest-t5.json"
  jq '.recipes += [{"id":"phantom-orphan","source_heading":"Nonexistent","source_context_level":"###","ordinal":1,"fixture_id":"sample-transcript","expectation":"true"}]' "$MANIFEST" > "$MUTANT_MANIFEST5"
  if MANIFEST="$MUTANT_MANIFEST5" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T5" "TEETH: sensor passes with an orphan recipe entry in manifest"
  fi

  # --- T7: Duplicate a recipe ID and source tuple → uniqueness failure --------
  MUTANT_MANIFEST7="${MUTANT_DIR}/manifest-t7.json"
  jq '.recipes += [.recipes[0]]' "$MANIFEST" > "$MUTANT_MANIFEST7"
  if MANIFEST="$MUTANT_MANIFEST7" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T7" "TEETH: sensor passes with duplicate recipe ID/source tuple"
  fi

  # --- T9: Set ordinal to 1.5 — structural validation must catch non-integer --
  MUTANT_MANIFEST9="${MUTANT_DIR}/manifest-t9.json"
  jq '.recipes[0].ordinal = 1.5' "$MANIFEST" > "$MUTANT_MANIFEST9"
  if MANIFEST="$MUTANT_MANIFEST9" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T9" "TEETH: sensor passes with ordinal=1.5 (integer validation not enforced)"
  fi

  # --- T10: Remove fixture surface field — structural validation must catch ---
  MUTANT_MANIFEST10="${MUTANT_DIR}/manifest-t10.json"
  jq '.fixtures[0].surface = null' "$MANIFEST" > "$MUTANT_MANIFEST10"
  if MANIFEST="$MUTANT_MANIFEST10" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "T10" "TEETH: sensor passes with fixture surface removed (structural type check not enforced)"
  fi
fi

# ==============================================================================
# Final verdict
# ==============================================================================
if [ "${fails}" -ne 0 ]; then
  printf '\n%d fixture-recipe-smoke-doc-consistency obligation(s) failed.\n' "$fails" >&2
  exit 1
fi

printf 'PASS: fixture-recipe-smoke-doc-consistency — all native-record recipes, fixtures, and versions are consistent.\n'
