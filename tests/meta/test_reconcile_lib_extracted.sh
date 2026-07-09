#!/usr/bin/env bash
# Regression sensor (issue #214, scripts-portfolio P-3). The dry/write/update
# three-way reconcile skeleton (create a missing target, no-op when it already
# matches, and on a diff either update / refuse / advise --update) was
# implemented twice — once in install-harness.sh and once in
# scaffold-language.sh, ~40 lines each. This sensor pins the extraction: the
# skeleton lives once in scripts/reconcile-lib.sh, both CLIs source it and
# delegate to reconcile_entry, and neither re-inlines a private copy.
#
# It is RED before the extraction (the callers carry the skeleton's signature
# messages and do not source the lib) and GREEN after.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
