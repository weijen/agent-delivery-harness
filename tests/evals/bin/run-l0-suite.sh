#!/usr/bin/env bash
# run-l0-suite.sh — L0 suite driver / CI gate for feature f2-l0-ci-gate (issue #64).
#
# Runs the L0 eval-case manifests through the sibling `run-evals.sh` runner,
# prints each case-level scorecard to stdout as evidence, and BLOCKS (exits
# non-zero) when any case is a blocking failure — i.e. when any scorecard result
# carries `blocking_decision == "block"`. This is the gate the harness-smoke CI
# workflow invokes so that breaking one L0 capability turns the job red with
# attributable, case-level evidence.
#
# Usage: run-l0-suite.sh [MANIFEST_DIR]
#   * NO arg  — runs the default L0 set `tests/evals/manifests/scripts/l0-*.json`.
#   * DIR arg — runs that directory's `l0-*.json` manifests (used by the sensor to
#               gate a synthetic temp set of manifests without touching real ones).
#
# Exit codes: 0 every case non-blocking · 1 at least one case blocked · 2 no
#             manifests matched / usage error. Scorecards are always emitted for
#             the cases that ran, regardless of the overall exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-evals.sh"
# Resolve the default L0 manifest dir to its absolute path, or leave it empty
# when the directory does not exist. Explicit if/then/else avoids the
# `A && B || C` (SC2015) pitfall where C can run when A succeeds but B fails.
if DEFAULT_MANIFEST_DIR="$(cd "${SCRIPT_DIR}/../manifests/scripts" 2>/dev/null && pwd)"; then
	:
else
	DEFAULT_MANIFEST_DIR=""
fi

if [ "$#" -gt 1 ]; then
	printf 'usage: %s [MANIFEST_DIR]\n' "$(basename "$0")" >&2
	exit 2
fi

command -v jq >/dev/null 2>&1 \
	|| { printf 'error: jq is required but was not found on PATH\n' >&2; exit 2; }

if [ ! -x "$RUNNER" ]; then
	printf 'error: eval runner not found or not executable: %s\n' "$RUNNER" >&2
	exit 2
fi

# Resolve the manifest directory: an explicit arg wins, otherwise the default
# real L0 set beside this script.
if [ "$#" -eq 1 ]; then
	arg_dir="$1"
	if [ ! -d "$arg_dir" ]; then
		printf 'error: manifest directory not found: %s\n' "$arg_dir" >&2
		exit 2
	fi
	MANIFEST_DIR="$(cd "$arg_dir" && pwd)"
else
	if [ -z "$DEFAULT_MANIFEST_DIR" ]; then
		printf 'error: default L0 manifest directory not found near %s\n' "$SCRIPT_DIR" >&2
		exit 2
	fi
	MANIFEST_DIR="$DEFAULT_MANIFEST_DIR"
fi

# Collect the l0-*.json manifests in sorted order (glob expansion is sorted;
# bash-3.2 portable — no mapfile/readarray).
declare -a manifests=()
for m in "$MANIFEST_DIR"/l0-*.json; do
	[ -e "$m" ] || continue
	manifests+=("$m")
done

if [ "${#manifests[@]}" -eq 0 ]; then
	printf 'error: no L0 manifests matched %s/l0-*.json\n' "$MANIFEST_DIR" >&2
	exit 2
fi

blocked=0

for manifest in "${manifests[@]}"; do
	# Capture the runner's scorecard. run-evals.sh exits non-zero for a blocking
	# case failure but still writes the scorecard to stdout first, so keep the
	# non-zero exit from aborting this driver under `set -e` and inspect the
	# scorecard's blocking_decision authoritatively via jq.
	rc=0
	scorecard="$(bash "$RUNNER" "$manifest" 2>/dev/null)" || rc=$?

	if [ -z "$scorecard" ]; then
		printf '# BLOCKING: no scorecard emitted for %s (runner exited %s)\n' "$manifest" "$rc" >&2
		blocked=1
		continue
	fi

	# Print the case-level scorecard as evidence.
	printf '%s\n' "$scorecard"

	# A case blocks iff any result row carries blocking_decision == "block".
	if printf '%s\n' "$scorecard" \
		| jq -e 'any(.results[]?; .blocking_decision == "block")' >/dev/null 2>&1; then
		blocked=1
	fi
done

if [ "$blocked" -ne 0 ]; then
	printf '# L0 suite gate: BLOCKING failure detected\n' >&2
	exit 1
fi

exit 0
