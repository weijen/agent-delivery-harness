#!/usr/bin/env bash
# L0 eval-manifest sensor (issue #64, feature f1-l0-manifests).
#
# Feature f1-l0-manifests ships five L0 eval-case manifests under
# tests/evals/manifests/scripts/, one per existing L0 harness sensor. This
# sensor proves — behaviorally, against the real assets — that each manifest:
#
#   1. exists and is VALID per tests/evals/bin/validate-manifest.sh (exit 0);
#   2. declares boundary == "script-lifecycle";
#   3. has a grader.command that invokes the matching existing L0 sensor
#      (the command string references that sensor's filename);
#   4. carries a non-empty contract_refs array in which EVERY "section:id"
#      entry resolves to a real entry in docs/harness-contract.yml.
#
# Assertion 4 depends on a portable contract-ref resolver. So that the resolver
# is not trivially always-true, this sensor first unit-tests it inline against a
# known-GOOD ref (failure_modes:stale-review-approval — a real entry) and a
# known-BAD ref (failure_modes:nope — no such entry); those two rows do not
# depend on the manifests existing.
#
# bash-3.2 portable: parallel indexed arrays (no associative arrays), no
# bash-4 bulk-read builtins, process substitution for the ref loop. Dogfoods
# tests/scripts/lib/tap.sh — one plan, continue past a failing row.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/harness-contract.yml"
VALIDATOR="${ROOT}/tests/evals/bin/validate-manifest.sh"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# jq is required by the validator and by the manifest field probes below; a
# missing jq is an honest environment failure, not a silent pass.
if ! command -v jq >/dev/null 2>&1; then
	tap_not_ok "jq is required on PATH for the L0 manifest sensor"
	tap_done
	exit $?
fi

# resolve_contract_ref <section:id> — returns 0 iff docs/harness-contract.yml
# has a top-level `<section>:` header AND, within that section's block (up to
# the next top-level header), a `- id: <id>` list entry. A ref without a colon,
# or with an empty section/id, does not resolve. Kept pragmatic but real: a
# bogus ref like failure_modes:nope, or a ref pointing an id at the wrong
# section, fails to resolve.
resolve_contract_ref() {
	local ref="$1" section id
	case "$ref" in
	*:*) ;;
	*) return 1 ;;
	esac
	section="${ref%%:*}"
	id="${ref#*:}"
	[ -n "$section" ] && [ -n "$id" ] || return 1

	awk -v section="$section" -v id="$id" '
		# Top-level section header: identifier at column 0 ending in ":".
		/^[A-Za-z_]+:/ {
			cur = $0
			sub(/:.*/, "", cur)
			in_section = (cur == section)
			next
		}
		in_section == 1 {
			line = $0
			sub(/^[[:space:]]+/, "", line)
			if (line == "- id: " id) { found = 1; exit }
		}
		END { exit (found ? 0 : 1) }
	' "$CONTRACT"
}

# --- Resolver self-check (independent of the manifests) --------------------
# A known-GOOD ref must resolve; a known-BAD ref must NOT resolve. Together
# these prove the resolver discriminates rather than always returning success.
if resolve_contract_ref "failure_modes:stale-review-approval"; then
	tap_ok "resolver: known-good ref failure_modes:stale-review-approval resolves"
else
	tap_not_ok "resolver: known-good ref failure_modes:stale-review-approval resolves"
fi

if resolve_contract_ref "failure_modes:nope"; then
	tap_not_ok "resolver: known-bad ref failure_modes:nope is rejected"
else
	tap_ok "resolver: known-bad ref failure_modes:nope is rejected"
fi

# --- Per-manifest assertions -----------------------------------------------
# Parallel arrays: manifest path (repo-relative) and the L0 sensor filename its
# grader.command must invoke. Index-aligned; bash-3.2 has no associative arrays.
MANIFEST_PATHS=(
	"tests/evals/manifests/scripts/l0-harness-contract.json"
	"tests/evals/manifests/scripts/l0-lifecycle-order.json"
	"tests/evals/manifests/scripts/l0-review-gate.json"
	"tests/evals/manifests/scripts/l0-feature-list.json"
	"tests/evals/manifests/scripts/l0-issue-scaffold.json"
)
SENSOR_FILES=(
	"test_harness_contract.sh"
	"test_lifecycle_order.sh"
	"test_review_gate.sh"
	"test_feature_list_check.sh"
	"test_issue_scaffold.sh"
)

i=0
while [ "$i" -lt "${#MANIFEST_PATHS[@]}" ]; do
	rel="${MANIFEST_PATHS[$i]}"
	sensor="${SENSOR_FILES[$i]}"
	abs="${ROOT}/${rel}"
	i=$((i + 1))

	# (1) exists AND valid per validate-manifest.sh (exit 0).
	if [ -f "$abs" ] && "$VALIDATOR" "$abs" >/dev/null 2>&1; then
		tap_ok "${rel}: exists and is a valid manifest"
	elif [ ! -f "$abs" ]; then
		tap_not_ok "${rel}: exists and is a valid manifest (missing: ${rel})"
	else
		tap_not_ok "${rel}: exists and is a valid manifest (invalid per validate-manifest.sh)"
	fi

	# (2) boundary == "script-lifecycle".
	boundary="$(jq -r '.boundary // empty' "$abs" 2>/dev/null || true)"
	tap_is "$boundary" "script-lifecycle" "${rel}: boundary is script-lifecycle"

	# (3) grader.command references the matching L0 sensor filename.
	cmd="$(jq -r '.grader.command // empty' "$abs" 2>/dev/null || true)"
	if [ -n "$cmd" ] && printf '%s' "$cmd" | grep -Fq "$sensor"; then
		tap_ok "${rel}: grader.command invokes ${sensor}"
	else
		tap_not_ok "${rel}: grader.command invokes ${sensor}"
	fi

	# (4) contract_refs is a non-empty array AND every entry resolves.
	reftype="$(jq -r '.contract_refs | type' "$abs" 2>/dev/null || echo null)"
	refcount="$(jq -r '(.contract_refs // []) | length' "$abs" 2>/dev/null || echo 0)"
	refs_ok=1
	if [ "$reftype" = "array" ] && [ "$refcount" -gt 0 ]; then
		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			if ! resolve_contract_ref "$ref"; then
				refs_ok=0
			fi
		done < <(jq -r '.contract_refs[]?' "$abs" 2>/dev/null || true)
	else
		refs_ok=0
	fi
	if [ "$refs_ok" -eq 1 ]; then
		tap_ok "${rel}: contract_refs non-empty and every entry resolves"
	else
		tap_not_ok "${rel}: contract_refs non-empty and every entry resolves"
	fi
done

tap_done
exit $?
