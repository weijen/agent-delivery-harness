#!/usr/bin/env bash
# Regression sensor (issue #215, scripts-portfolio P-4). finish-issue.sh had
# grown into a second conductor: completion check + trace gate + trace export +
# trace reconstruct + state hygiene + worktree teardown, with every new closeout
# feature landing in it. This sensor pins the extraction: the four best-effort /
# gate helpers live once in scripts/finish-lib.sh, finish-issue.sh sources it and
# delegates, and it no longer re-inlines the helper bodies. It also guards the
# "sequence orchestrator" shape (net line reduction).
#
# It is RED before the extraction (finish-lib.sh is absent and finish-issue.sh
# carries the helper bodies) and GREEN after.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }
ok() { echo "· $*"; }

LIB="scripts/finish-lib.sh"
CALLER="scripts/finish-issue.sh"
HELPERS="finish_trace_gate best_effort_state_hygiene"

# --- A. The shared lib exists and defines the closeout helpers ---------------
if [ ! -f "$LIB" ]; then
	note "$LIB missing — the closeout helpers are not extracted"
else
	ok "shared lib present: $LIB"
	for fn in $HELPERS; do
		grep -Eq "^${fn}[[:space:]]*\(\)" "$LIB" ||
			note "$LIB does not define ${fn}()"
	done
fi

# --- B. finish-issue.sh sources the lib and delegates -----------------------
if [ ! -f "$CALLER" ]; then
	note "$CALLER missing"
else
	grep -Eq 'finish-lib\.sh' "$CALLER" ||
		note "$CALLER does not source finish-lib.sh"
	grep -Eq 'finish_trace_gate' "$CALLER" ||
		note "$CALLER does not delegate to finish_trace_gate"

	# --- C. finish-issue.sh no longer re-inlines the helper bodies ----------
	# A body carries multi-line logic; a NOOP fallback (`() { return 0; }`) does
	# not. Assert none of the helpers is DEFINED with a real (non-NOOP) body in
	# finish-issue.sh — i.e. any definition line must be the single-line NOOP
	# fallback, never a multi-line body.
	for fn in $HELPERS; do
		def="$(grep -nE "^${fn}[[:space:]]*\(\)" "$CALLER" || true)"
		if [ -n "$def" ]; then
			# Allow ONLY the one-line NOOP fallback form on the same line.
			if ! grep -Eq "^${fn}\(\) \{ return 0; \}$" "$CALLER"; then
				note "$CALLER re-inlines a real body for ${fn}() (it belongs only in $LIB)"
			fi
		fi
	done

	# Signature messages that live inside the extracted bodies must not reappear
	# inline in the orchestrator.
	for msg in 'Exported trace for issue' 'Reconstructed trace for issue' 'Swept orphaned hook-state'; do
		grep -qF "$msg" "$CALLER" &&
			note "$CALLER re-inlines helper output '$msg' (belongs only in $LIB)"
	done
fi

# --- D. Net line reduction: the orchestrator is meaningfully slimmer --------
if [ -f "$CALLER" ]; then
	lines="$(wc -l <"$CALLER" | tr -d ' ')"
	ok "$CALLER is ${lines} lines"
	# The pre-extraction script was ~284 lines; a genuine extraction leaves the
	# orchestrator well under 240 (helper bodies + gate block removed).
	if [ "$lines" -ge 240 ]; then
		note "$CALLER is ${lines} lines — expected net reduction below 240 after extraction"
	fi
fi

# --- E. The lib ships with the harness --------------------------------------
# scripts/finish-lib.sh lives under scripts/, which install-harness copies
# wholesale via its asset manifest; assert that manifest entry is intact.
if grep -Eq '^[[:space:]]*scripts[[:space:]]*$' scripts/install-harness.sh; then
	ok "install-harness manifest ships scripts/ wholesale (covers $LIB)"
else
	note "install-harness manifest no longer ships scripts/ wholesale — add $LIB to the manifest explicitly"
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "finish-lib extraction sensor FAILED (RED)"
	exit 1
fi
echo "finish-lib extraction checks passed"
