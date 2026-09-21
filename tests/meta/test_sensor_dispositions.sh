#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'sensor-dispositions: %s\n' "$*" >&2; exit 1; }
FIX="$TMP/repo"
mkdir -p "$FIX/tests/scripts"
cat >"$FIX/tests/scripts/test_routine.sh" <<'SH'
#!/usr/bin/env bash
# harness-sensor-depends: scripts/lib/runtime.sh
:
SH
for disposition in relevant upgrade maintenance; do
	cat >"$FIX/tests/scripts/test_${disposition}.sh" <<SH
#!/usr/bin/env bash
# harness-sensor-trigger: ${disposition}
# harness-sensor-depends: scripts/${disposition}.sh scripts/lib/shared.sh fixtures/${disposition}/* docs/active.yml
:
SH
done
cat >"$FIX/tests/scripts/test_boundary.sh" <<'SH'
#!/usr/bin/env bash
# harness-sensor-stage: boundary
# harness-sensor-trigger: upgrade
# harness-sensor-depends: scripts/upgrade.sh
:
SH
resolve() {
	"$ROOT/scripts/validation/affected-sensors.sh" --repo-root "$FIX" "$@"
}
expect() {
	local wanted="$1"; shift
	resolve "$@" >"$TMP/actual" 2>"$TMP/error" \
		|| { cat "$TMP/error" >&2; fail "valid disposition selection failed"; }
	printf '%s\n' "$wanted" | sed '/^$/d' | LC_ALL=C sort >"$TMP/expected"
	cmp -s "$TMP/expected" "$TMP/actual" \
		|| { cat "$TMP/actual" >&2; fail "unexpected set for $*"; }
}
routine=tests/scripts/test_routine.sh
relevant=tests/scripts/test_relevant.sh
upgrade=tests/scripts/test_upgrade.sh
maintenance=tests/scripts/test_maintenance.sh
boundary=tests/scripts/test_boundary.sh

expect "$routine" --gate pre-pr unrelated.md
expect "$routine"$'\n'"$relevant" --gate pre-pr scripts/relevant.sh
expect "$routine"$'\n'"$maintenance" --gate pre-pr fixtures/maintenance/input.json
expect "$routine"$'\n'"$upgrade"$'\n'"$boundary" --gate pre-pr scripts/upgrade.sh
expect "$routine"$'\n'"$relevant"$'\n'"$upgrade"$'\n'"$maintenance" --gate pre-pr scripts/lib/shared.sh
expect "$upgrade"$'\n'"$boundary" --gate release
expect "$maintenance" --gate maintenance
expect "$routine" scripts/lib/runtime.sh
expect "$relevant" --declared "$relevant" unrelated.md
expect "$upgrade" scripts/upgrade.sh
expect "$maintenance" tests/scripts/test_maintenance.sh
expect "$routine"$'\n'"$relevant"$'\n'"$upgrade"$'\n'"$maintenance"$'\n'"$boundary" --list

# Common prose basenames cannot accidentally trigger an entire maintenance group.
printf '# README.md\n' >>"$FIX/tests/scripts/test_maintenance.sh"
expect "$routine" --gate pre-pr docs/README.md

reject() {
	local diagnostic="$1"; shift
	local status=0
	resolve "$@" >"$TMP/actual" 2>"$TMP/error" || status=$?
	[ "$status" = 2 ] || fail "invalid selection did not fail with usage/discovery status"
	[ ! -s "$TMP/actual" ] || fail "invalid selection emitted partial success"
	grep -Eqi "$diagnostic" "$TMP/error" || { cat "$TMP/error" >&2; fail "missing corrective diagnostic"; }
}
reject boundary-only --declared "$boundary" scripts/upgrade.sh
reject 'diff|changed' --gate pre-pr
reject 'gate' --gate invented unrelated.md
printf '#!/usr/bin/env bash\n# harness-sensor-trigger: invented\n:\n' >"$FIX/tests/scripts/test_invalid.sh"
reject 'metadata|trigger' --gate pre-pr unrelated.md
printf '#!/usr/bin/env bash\n# harness-sensor-trigger: maintenance\n:\n' >"$FIX/tests/scripts/test_invalid.sh"
reject 'depend' --gate maintenance
printf '#!/usr/bin/env bash\n# harness-sensor-depends: ../outside\n:\n' >"$FIX/tests/scripts/test_invalid.sh"
reject 'depend|unsafe' --gate pre-pr unrelated.md
printf '#!/usr/bin/env bash\n# harness-sensor-deletes: ../outside\n:\n' >"$FIX/tests/scripts/test_invalid.sh"
reject 'depend|unsafe' --gate pre-pr unrelated.md
printf '#!/usr/bin/env bash\n# harness-sensor-deletes: profiles/*\n# harness-sensor-deletes: scripts/*\n:\n' >"$FIX/tests/scripts/test_invalid.sh"
reject 'metadata' --gate pre-pr unrelated.md

source_resolve() {
	"$ROOT/scripts/validation/affected-sensors.sh" "$@" >"$TMP/source"
}
source_resolve --gate pre-pr unrelated-product.txt
scoped=(
	tests/scripts/maintenance/test_audit_sweep.sh
	tests/scripts/test_copilot_log_review_recipes.sh
	tests/scripts/test_economics_span.sh
	tests/meta/test_archived_reports.sh
	tests/scripts/test_release_workflow.sh
	tests/scripts/test_release_lock_sync.sh
	tests/scripts/maintenance/test_install_harness_tombstone_history.sh
)
for sensor in "${scoped[@]}"; do
	if grep -Fxq "$sensor" "$TMP/source"; then fail "$sensor still runs for unrelated final gates"; fi
done
for sensor in "${scoped[@]}"; do
	source_resolve --gate pre-pr "$sensor"
	grep -Fxq "$sensor" "$TMP/source" || fail "$sensor omitted its own change"
done
source_resolve scripts/lib/lifecycle-runtime-lib.sh
grep -Fxq tests/scripts/lifecycle/test_create_pr_sensor_gate.sh "$TMP/source" \
	|| fail "implicit fixture dependency omitted the publication consumer"
source_resolve --gate pre-pr scripts/lib/trace-lib.sh
for sensor in tests/scripts/test_economics_span.sh tests/scripts/test_trace_lib_redaction.sh; do
	grep -Fxq "$sensor" "$TMP/source" || fail "shared trace dependency omitted $sensor"
done
source_resolve --gate maintenance
for sensor in tests/scripts/maintenance/test_audit_sweep.sh tests/scripts/test_copilot_log_review_recipes.sh tests/meta/test_archived_reports.sh; do
	grep -Fxq "$sensor" "$TMP/source" || fail "explicit maintenance omitted $sensor"
done
source_resolve --gate release
for sensor in tests/scripts/test_release_workflow.sh tests/scripts/test_release_lock_sync.sh tests/scripts/maintenance/test_install_harness_tombstone_history.sh; do
	grep -Fxq "$sensor" "$TMP/source" || fail "release omitted $sensor"
done
grep -Fxq 'tests/meta/test_*.sh' "$ROOT/tests/harness-dev-sensors.txt" \
	|| fail "source policy assertions must not ship as adopter sensors"
source_resolve --gate pre-pr scripts/lib/reconcile-lib.sh
grep -Fxq tests/scripts/maintenance/test_install_harness_tombstone_history.sh "$TMP/source" \
	|| fail "retirement acceptance omitted the actual reconciliation dependency"

# Real deletion history, policy metadata and runner; no source-suite replay.
HISTORY="$TMP/history"
mkdir -p "$HISTORY/scripts/validation" "$HISTORY/scripts/lib" "$HISTORY/scripts/maintenance" "$HISTORY/tests/scripts"
cp "$ROOT/scripts/run-sensors.sh" "$HISTORY/scripts/"
cp "$ROOT/scripts/maintenance/check-install-harness-tombstones.sh" "$HISTORY/scripts/maintenance/"
cp "$ROOT/scripts/validation/"{run-sensors,affected-sensors}.sh "$HISTORY/scripts/validation/"
cp "$ROOT/scripts/lib/trace-lib.sh" "$HISTORY/scripts/lib/"
{
	printf '#!/usr/bin/env bash\n'
	grep '^# harness-sensor-' "$ROOT/tests/scripts/maintenance/test_install_harness_tombstone_history.sh"
	printf 'bash scripts/maintenance/check-install-harness-tombstones.sh .\n'
} >"$HISTORY/tests/scripts/test_history.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HISTORY/tests/scripts/test_routine.sh"
printf '#!/usr/bin/env bash\n' >"$HISTORY/scripts/install-harness.sh"
: >"$HISTORY/scripts/install-harness.tombstones"
printf '/.copilot-tracking/\n' >"$HISTORY/.gitignore"
managed=(
	profiles/retired.profile.sh scripts/retired.sh tests/fixtures/retired.txt
	.copilot/instructions/retired.md .github/workflows/harness-smoke.yml
	docs/HARNESS.md optional/runtime-adapters/retired.sh VERSION
)
for path in "${managed[@]}"; do
	mkdir -p "$HISTORY/$(dirname "$path")"
	printf 'managed fixture\n' >"$HISTORY/$path"
done
git -C "$HISTORY" init -q -b main
git -C "$HISTORY" config user.name "Harness Test"
git -C "$HISTORY" config user.email "harness-test@example.invalid"
git -C "$HISTORY" config commit.gpgsign false
git -C "$HISTORY" add .
git -C "$HISTORY" commit -qm 'test: managed history baseline'
git -C "$HISTORY" update-ref refs/remotes/origin/main HEAD
printf 'ordinary update\n' >>"$HISTORY/profiles/retired.profile.sh"
git -C "$HISTORY" commit -qam 'test: ordinary profile update'
(cd "$HISTORY" && ./scripts/run-sensors.sh --gate pre-pr) >"$TMP/history.out" 2>&1 \
	|| { cat "$TMP/history.out" >&2; fail "ordinary update gate failed"; }
grep -q 'scope=applicable ran=1 failed=0$' "$TMP/history.out" \
	|| fail "ordinary profile update must not replay deletion history"
for path in "${managed[@]}"; do
	digest="$(shasum -a 256 "$HISTORY/$path" | awk '{print $1}')"
	rm "$HISTORY/$path"
	for phase in unstaged staged; do
		if [ "$phase" = staged ]; then git -C "$HISTORY" add "$path"; fi
		"$HISTORY/scripts/validation/affected-sensors.sh" --gate pre-pr --diff origin/main >"$TMP/history.selected"
		grep -Fxq tests/scripts/test_history.sh "$TMP/history.selected" \
			|| fail "$phase deletion of $path omitted history acceptance"
	done
	git -C "$HISTORY" commit -qm 'test: managed deletion without ledger'
	rc=0
	(cd "$HISTORY" && ./scripts/run-sensors.sh --gate pre-pr) >"$TMP/history.out" 2>&1 || rc=$?
	if [ "$rc" != 1 ] || ! grep -q 'missing managed deletion history' "$TMP/history.out"; then
		cat "$TMP/history.out" >&2
		fail "committed deletion of $path did not fail the actual checker through the runner"
	fi
	printf '%s\t%s\n' "$digest" "$path" >>"$HISTORY/scripts/install-harness.tombstones"
	git -C "$HISTORY" commit -qam 'test: acknowledge managed deletion'
	(cd "$HISTORY" && ./scripts/run-sensors.sh --gate pre-pr) >"$TMP/history.out" 2>&1 \
		|| { cat "$TMP/history.out" >&2; fail "correct ledger failed for $path"; }
	git -C "$HISTORY" update-ref refs/remotes/origin/main HEAD
done
printf 'bounded dispositions and known dependency obligations honored\n'
