#!/usr/bin/env bash
# Regression sensor (issue #217, scripts-portfolio P-6/P-7/P-8 + §2.5). The
# scripts/ language & structure policy must be recorded in one page under docs/
# so future sessions don't relitigate it, linked from HARNESS.md's layers
# section and cross-referencing the rationale record
# docs/scripts-portfolio-review.md.
#
# This is the docs-feature TDD-equivalent: it is RED before the policy page
# exists (and before HARNESS.md links it) and GREEN once both are in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

POLICY="docs/scripts-language-policy.md"
HARNESS="docs/HARNESS.md"
RATIONALE="docs/scripts-portfolio-review.md"

fail=0
note() { echo "✗ $*"; fail=1; }
ok() { echo "· $*"; }

# --- A. The policy page exists and records the three decisions ---------------
if [ ! -f "$POLICY" ]; then
	note "$POLICY missing — the scripts language & structure policy is not recorded"
else
	ok "policy page present: $POLICY"
	# 1. Stays bash indefinitely (lifecycle core + emission + hooks).
	grep -qiE 'stays?[ -]bash' "$POLICY" ||
		note "$POLICY does not state what stays bash"
	# 2. May become Python, trigger-based, behind frozen CLI contracts.
	grep -qiE 'python' "$POLICY" ||
		note "$POLICY does not state what may become Python"
	grep -qiE 'trigger' "$POLICY" ||
		note "$POLICY does not state the Python migration is trigger-based"
	# 3. Split thresholds: review-gate.d split, no mono-CLI.
	grep -qF 'review-gate.d' "$POLICY" ||
		note "$POLICY does not name the review-gate.d split threshold"
	grep -qiE 'no unified|no .*mono-?cli|without a .*mono-?cli|not .*mono-?cli' "$POLICY" ||
		note "$POLICY does not record the no-unified-CLI decision"
	# Cross-reference the rationale record.
	grep -qF 'scripts-portfolio-review.md' "$POLICY" ||
		note "$POLICY does not cross-reference the rationale record $RATIONALE"
fi

# --- B. HARNESS.md links the policy from its layers section ------------------
if grep -qF 'scripts-language-policy.md' "$HARNESS"; then
	ok "$HARNESS links the policy page"
else
	note "$HARNESS does not link $POLICY from its layers section"
fi

# --- C. Links resolve --------------------------------------------------------
[ -f "$RATIONALE" ] || note "rationale record $RATIONALE missing (broken cross-reference)"

echo
if [ "$fail" -ne 0 ]; then
	echo "scripts-language-policy doc sensor FAILED (RED)"
	exit 1
fi
echo "scripts-language-policy doc checks passed"
