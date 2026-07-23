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

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }
ok() { echo "· $*"; }

LIB="scripts/reconcile-lib.sh"
CALLERS="scripts/install-harness.sh scripts/scaffold-language.sh"

# --- A. The shared lib exists and owns the skeleton -------------------------
if [ ! -f "$LIB" ]; then
	note "$LIB missing — the shared reconcile skeleton is not extracted"
else
	ok "shared lib present: $LIB"
	grep -Eq '^reconcile_entry[[:space:]]*\(\)' "$LIB" ||
		note "$LIB does not define reconcile_entry()"
	# The skeleton's signature messages belong here (single source).
	for msg in 'would create %s' 'up to date %s' 'updating %s' 'refusing to overwrite %s'; do
		grep -qF "$msg" "$LIB" ||
			note "$LIB is missing the skeleton message '$msg' (the extracted body must own it)"
	done
fi

# --- B. Both CLIs source the lib and delegate; neither re-inlines it --------
for caller in $CALLERS; do
	if [ ! -f "$caller" ]; then
		note "$caller missing"
		continue
	fi
	grep -Eq 'reconcile-lib\.sh' "$caller" ||
		note "$caller does not source reconcile-lib.sh"
	grep -Eq 'reconcile_entry' "$caller" ||
		note "$caller does not delegate to reconcile_entry"
	# A re-inlined skeleton would carry these signature messages itself.
	for msg in 'would create %s' 'up to date %s'; do
		if grep -qF "$msg" "$caller"; then
			note "$caller re-inlines the reconcile skeleton ('$msg' belongs only in $LIB)"
		fi
	done
done

# --- C. The lib ships with the harness --------------------------------------
# scripts/reconcile-lib.sh lives under scripts/, which install-harness copies
# wholesale via its asset manifest; assert that manifest entry is intact.
if grep -Eq '^[[:space:]]*scripts[[:space:]]*$' scripts/install-harness.sh; then
	ok "install-harness manifest ships scripts/ wholesale (covers $LIB)"
else
	note "install-harness manifest no longer ships scripts/ wholesale — add $LIB to the manifest explicitly"
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "reconcile-lib extraction sensor FAILED (RED)"
	exit 1
fi
echo "reconcile-lib extraction checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

lib="scripts/trace-lib.sh"
# The four scripts that emit exactly ONE terminal lifecycle span from an EXIT trap.
lifecycle_scripts="start-issue.sh create-pr.sh merge-pr.sh finish-issue.sh"

fail=0
note() { echo "✗ $*"; fail=1; }

[ -f "$lib" ] || { echo "✗ missing $lib"; exit 1; }

# --- Direction 1: the shared helper exists in trace-lib.sh --------------------
grep -qE '^trace_lifecycle_init\(\)' "$lib" ||
  note "${lib} must define the shared helper trace_lifecycle_init()"
grep -qE '^trace_lifecycle_arm\(\)' "$lib" ||
  note "${lib} must define the shared helper trace_lifecycle_arm()"

# --- Direction 2: no lifecycle script carries an inline terminal-trap copy ----
for base in $lifecycle_scripts; do
  f="scripts/${base}"
  [ -f "$f" ] || { note "expected lifecycle script ${f} is missing"; continue; }

  # Must route through the shared helper.
  grep -qE '\btrace_lifecycle_init\b' "$f" ||
    note "${f} must call trace_lifecycle_init (use the shared helper, not an inline trap)"
  grep -qE '\btrace_lifecycle_arm\b' "$f" ||
    note "${f} must call trace_lifecycle_arm (arm the shared helper's terminal span)"

  # Must NOT define its own terminal EXIT-trap function ...
  if grep -qE '^trace__[A-Za-z0-9_]*_exit\(\)' "$f"; then
    note "${f} defines an inline trace__*_exit() trap function — extract it into trace-lib.sh trace_lifecycle_init instead"
  fi
  # ... nor install one via trap.
  if grep -qE 'trap[[:space:]]+.*trace__[A-Za-z0-9_]*_exit.*EXIT' "$f"; then
    note "${f} installs an inline trace__*_exit EXIT trap — use trace_lifecycle_init instead"
  fi
  # ... nor emit a lifecycle terminal span outside the helper via a hand-rolled trap.
  if grep -qE 'trace_span[[:space:]]+lifecycle' "$f" &&
     grep -qE '^trace__[A-Za-z0-9_]*_exit\(\)' "$f"; then
    note "${f} emits a lifecycle span from an inline trap — route it through trace_lifecycle_init"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "lifecycle-trap drift sensor FAILED"
  exit 1
fi
echo "lifecycle-trap drift checks passed"
)
