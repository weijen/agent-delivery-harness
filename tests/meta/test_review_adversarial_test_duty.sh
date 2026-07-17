#!/usr/bin/env bash
# Regression sensor (issue #296): independent review may add and execute only
# adversarial test assets, while production repair remains generator-owned.
# The sensor checks section structure and cross-file ownership vocabulary rather
# than pinning editable prose.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

reviewer=".copilot/agents/code-review-subagent.agent.md"
active_doctrine=(
	.copilot/instructions/harness.instructions.md
	AGENTS.md
	docs/HARNESS.md
	docs/evaluation/product-quality-rubric.md
)

extract_frontmatter() {
	awk 'NR == 1 && $0 == "---" { capture=1; next } capture && $0 == "---" { exit } capture { print }' "$1"
}

extract_section() {
	local file="$1"
	local heading_pattern="$2"
	awk -v heading_pattern="$heading_pattern" '
		/^```/ { in_fence = !in_fence; if (capture) print; next }
		!in_fence && match($0, /^(##+) /) {
			level = RLENGTH - 1
			title = substr($0, RLENGTH + 1)
			if (!capture && title ~ "^(" heading_pattern ")$") {
				capture=1
				capture_level=level
				next
			}
			if (capture && level <= capture_level) { exit }
		}
		capture { print }
	' "$file"
}

assert_pattern() {
	local text="$1"
	local pattern="$2"
	local message="$3"
	printf '%s\n' "$text" | grep -Eiq "$pattern" || note "$message"
}

if [ ! -f "$reviewer" ]; then
	note "missing $reviewer"
else
	frontmatter="$(extract_frontmatter "$reviewer")"
	adversarial_section="$(extract_section "$reviewer" 'Adversarial Test-Quality Pass')"
	output_section="$(extract_section "$reviewer" 'Output Format|Response Format')"

	for tool in read edit search execute; do
		assert_pattern "$frontmatter" "(^|[[:space:],[])[\"']?${tool}[\"']?([][:space:],]|$)" \
			"$reviewer frontmatter must provide '$tool' capability"
	done

	[ -n "$adversarial_section" ] \
		|| note "$reviewer must define an Adversarial Test-Quality Pass section"
	assert_pattern "$adversarial_section" 'criterion.*sensor|sensor.*criterion' \
		"adversarial pass must map criteria to sensors"
	assert_pattern "$adversarial_section" 'assertion.*strength|strength.*assertion' \
		"adversarial pass must assess assertion strength"
	assert_pattern "$adversarial_section" 'boundar|negative|mutation' \
		"adversarial pass must assess boundary, negative, or mutation cases"
	assert_pattern "$adversarial_section" 'implementation.fit|fit.*implementation' \
		"adversarial pass must detect tests fitted to the implementation"
	assert_pattern "$adversarial_section" 'smallest.*independent.*test|independent.*test' \
		"adversarial pass must permit the smallest independent test"
	assert_pattern "$adversarial_section" 'run|execut' \
		"adversarial pass must execute its added sensor"
	assert_pattern "$adversarial_section" 'test|fixture|smoke|validation' \
		"reviewer edit authority must name dedicated verification assets"
	assert_pattern "$adversarial_section" 'must not.*production|never.*production|production.*read.only|forbid.*production' \
		"reviewer must explicitly forbid production edits"
	assert_pattern "$adversarial_section" 'ambiguous|production hook' \
		"ambiguous paths or required production hooks must stop reviewer edits"
	assert_pattern "$adversarial_section" 'NEEDS_REVISION' \
		"a newly exposed production failure must produce NEEDS_REVISION"
	assert_pattern "$adversarial_section" 'conductor.*generator-subagent|generator-subagent.*conductor' \
		"production repair must route through the conductor to generator-subagent"
	assert_pattern "$adversarial_section" 're-?run|rerun' \
		"reviewer must rerun the adversarial sensor after repair"

	assert_pattern "$output_section" 'test files changed|changed tests' \
		"review output must list changed test files"
	assert_pattern "$output_section" 'commands' \
		"review output must list executed commands"
	assert_pattern "$output_section" 'evidence|observed result|pass/fail' \
		"review output must include command evidence and pass/fail results"
fi

for doc in "${active_doctrine[@]}"; do
	if [ ! -f "$doc" ]; then
		note "missing active doctrine $doc"
		continue
	fi
	doc_text="$(cat "$doc")"
	assert_pattern "$doc_text" 'code-review-subagent|Reviewer' \
		"$doc must identify reviewer ownership"
	assert_pattern "$doc_text" 'adversarial.*test|independent.*test|test.*adversarial' \
		"$doc must assign adversarial independent testing to review"
	assert_pattern "$doc_text" 'test|fixture|smoke|validation' \
		"$doc must bound reviewer writes to verification assets"
	assert_pattern "$doc_text" 'must not.*production|never.*production|production.*read.only|forbid.*production' \
		"$doc must prohibit reviewer production edits"
	assert_pattern "$doc_text" 'generator-subagent' \
		"$doc must route production repair to generator-subagent"
done

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "review adversarial test duty checks passed"