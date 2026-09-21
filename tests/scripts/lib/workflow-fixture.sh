#!/usr/bin/env bash
# Extract actual workflow commands for both miniature and installed tests.
extract_workflow_step() {
	local workflow="$1" id="$2" output="$3"
	awk -v id="$id" '
		/^      - / { selected = ($0 == "      - id: " id); running = 0 }
		/^        id: / { selected = ($0 == "        id: " id) }
		selected && /^        run: \|$/ { running = 1; next }
		running && /^          / { print substr($0, 11); next }
		running && NF { running = 0 }
	' "$workflow" >"$output"
	if [ ! -s "$output" ]; then
		printf 'missing executable workflow step: %s\n' "$id" >&2
		return 1
	fi
	bash -n "$output"
}
