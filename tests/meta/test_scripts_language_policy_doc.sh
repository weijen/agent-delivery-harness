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
	# 3. Split thresholds: review-gate.d, scripts/trace_tools, no mono-CLI.
	grep -qF 'review-gate.d' "$POLICY" ||
		note "$POLICY does not name the review-gate.d split threshold"
	grep -qF 'scripts/trace_tools' "$POLICY" ||
		note "$POLICY does not name the scripts/trace_tools Python-package home"
	grep -qiE 'no unified|no .*mono-?cli|without a .*mono-?cli|not .*mono-?cli' "$POLICY" ||
		note "$POLICY does not record the no-unified-CLI decision"
	# Cross-reference the rationale record.
	grep -qF 'scripts-portfolio-review.md' "$POLICY" ||
		note "$POLICY does not cross-reference the rationale record $RATIONALE"
fi

# --- A2. §2 records the issue-#220 Python-vs-jq decision-gate verdict --------
# (issue #220) The trace-export.sh pilot decision gate must be resolved in the
# policy page itself so the trigger-based §2 rule now carries a recorded verdict.
if [ -f "$POLICY" ]; then
	# 1. A decision-gate verdict tied to issue #220.
	if grep -qF '#220' "$POLICY" &&
		grep -qiE 'decision[ -]gate|verdict' "$POLICY"; then
		ok "$POLICY records an issue-#220 decision-gate verdict"
	else
		note "$POLICY does not record the issue-#220 Python-vs-jq decision-gate verdict"
	fi
	# 2. Verdict outcome: qualified win for the trace-analytics / data-mapping
	#    cluster — adopt the scripts/trace_tools dispatcher, jq stays the fallback.
	grep -qiE 'qualified win' "$POLICY" ||
		note "$POLICY does not record the trace-export.sh pilot as a qualified win"
	grep -qiE 'fallback' "$POLICY" ||
		note "$POLICY verdict does not keep jq as the always-available fallback"
	# 3. Not wholesale — remaining analytics tools migrate only on their own
	#    trigger (verdict must tie to the trigger-based / never-wholesale rule).
	grep -qiE 'never wholesale|not wholesale|trigger' "$POLICY" ||
		note "$POLICY verdict does not tie to the trigger-based / never-wholesale rule"
	# 4. A Phase-2 migration issue is recommended.
	if grep -qiE 'Phase[ -]2' "$POLICY" &&
		grep -qiE 'migration' "$POLICY"; then
		ok "$POLICY recommends a Phase-2 migration issue"
	else
		note "$POLICY does not recommend a Phase-2 migration issue"
	fi
	# 5. The verdict was reported back to epic #212.
	grep -qF '#212' "$POLICY" ||
		note "$POLICY does not record that the verdict was reported to epic #212"
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
