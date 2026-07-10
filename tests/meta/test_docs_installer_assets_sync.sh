#!/usr/bin/env bash
# Regression sensor (issue #269): the getting-started installer walkthrough must
# name every `.copilot/*` asset group the installer actually copies, so the docs
# cannot drift from scripts/install-harness.sh HARNESS_ASSETS. install-harness.sh
# is the authority; this sensor fails if a copied `.copilot/*` group is not named
# in docs/getting-started.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

installer="scripts/install-harness.sh"
guide="docs/getting-started.md"

[ -f "$installer" ] || note "missing $installer"
[ -f "$guide" ] || note "missing $guide"

if [ -f "$installer" ] && [ -f "$guide" ]; then
	# Extract the HARNESS_ASSETS array body and keep only .copilot/* entries.
	copilot_assets="$(
		awk '
			/^HARNESS_ASSETS=\(/ { infield = 1; next }
			infield && /^\)/ { infield = 0 }
			infield { print $1 }
		' "$installer" | grep '^\.copilot/' | LC_ALL=C sort -u
	)"

	[ -n "$copilot_assets" ] \
		|| note "$installer: could not extract any .copilot/* HARNESS_ASSETS entries"

	while IFS= read -r asset; do
		[ -z "$asset" ] && continue
		# The guide may write the group with or without a trailing slash.
		if ! grep -qF "$asset" "$guide" && ! grep -qF "${asset}/" "$guide"; then
			note "$guide does not name the installer asset group '$asset' (drift from $installer HARNESS_ASSETS)"
		fi
	done <<< "$copilot_assets"
fi

if [ "$fail" -ne 0 ]; then
	echo "installer/getting-started asset-sync sensor FAILED"
	exit 1
fi
printf 'installer/getting-started asset-sync sensor passed\n'
