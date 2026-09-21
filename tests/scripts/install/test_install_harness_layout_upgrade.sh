#!/usr/bin/env bash
# harness-sensor-trigger: upgrade
# harness-sensor-depends: scripts/install-harness* scripts/scaffold-language.sh scripts/install/* scripts/init.sh scripts/start-issue.sh scripts/create-pr.sh scripts/merge-pr.sh scripts/finish-issue.sh scripts/lifecycle/* scripts/check-trace-consistency.sh scripts/trace/* scripts/log-handback.sh scripts/render-action-log.sh scripts/lib/reconcile-lib.sh scripts/lib/github-identity-lib.sh scripts/lib/trace-lib.sh scripts/lib/issue-lib.sh scripts/run-sensors.sh scripts/validation/run-sensors.sh scripts/validation/affected-sensors.sh profiles/adopter-smoke.yml tests/harness-dev-sensors.txt docs/harness-contract.yml optional/runtime-adapters/* VERSION
# Genuine v0.45.2 installed-layout acceptance, separated from profile selection.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'layout-upgrade disposition: %s\n' "$*" >&2; exit 1; }
upgrades=(
	tests/scripts/install/test_install_harness_layout_upgrade.sh
	tests/scripts/install/test_install_harness_version_skew.sh
)
resolver="$ROOT/scripts/validation/affected-sensors.sh"
"$resolver" --gate pre-pr unrelated-product.txt >"$TMP_DIR/selected"
for sensor in "${upgrades[@]}"; do
	if grep -Fxq "$sensor" "$TMP_DIR/selected"; then fail "unrelated change selected $sensor"; fi
done
for path in scripts/install-harness.sh scripts/install-harness.assets scripts/install-harness.dev.assets \
	scripts/install-harness.tombstones scripts/lib/reconcile-lib.sh scripts/lib/trace-lib.sh \
	docs/harness-contract.yml profiles/adopter-smoke.yml; do
	"$resolver" --gate pre-pr "$path" >"$TMP_DIR/selected"
	for sensor in "${upgrades[@]}"; do
		grep -Fxq "$sensor" "$TMP_DIR/selected" || fail "$path omitted $sensor"
	done
done
"$resolver" --gate release >"$TMP_DIR/selected"
for sensor in "${upgrades[@]}"; do
	grep -Fxq "$sensor" "$TMP_DIR/selected" || fail "release omitted $sensor"
done
if grep -q 'archive v0.45.2' "$ROOT/tests/scripts/install/test_install_harness_adopter_profile.sh"; then
	fail "routine profile sensor still replays the historical matrix"
fi

layout_log="${TMP_DIR}/layout-upgrade.log"
fail_layout() {
	[ ! -f "$layout_log" ] || cat "$layout_log" >&2
	printf 'FAIL: layout upgrade: %s\n' "$*" >&2
	exit 1
}
install_layout() {
	layout_install_calls=$((layout_install_calls + 1))
	"$@" >"$layout_log" 2>&1
}
legacy_source="${TMP_DIR}/previous-layout"
mkdir -p "$legacy_source"
# The pre-layout release is an explicit reusable-asset fixture, not a checkout
# archive: project-owned environment files and local bindings are not inputs.
git -C "$ROOT" archive v0.45.2 scripts profiles tests .copilot docs schemas optional VERSION \
	.github/harness-identity.env.example | tar -x -C "$legacy_source"
awk '
	function emit() {
		if (old != "") print old "\t" canonical "\t" (audience == "" ? "installed" : audience) "\t" public
		old=canonical=public=audience=""
	}
	/^layout_moves:/ { selected=1; next }
	selected && /^[^ #]/ { exit }
	selected && /^  - from:/ { emit(); old=$3 }
	selected && /^    to:/ { canonical=$2 }
	selected && /^    public_entrypoint:/ { public=$2 }
	selected && /^    audience:/ { audience=$2 }
	END { emit() }
' "${ROOT}/docs/harness-contract.yml" >"${TMP_DIR}/layout-moves"
[ -s "${TMP_DIR}/layout-moves" ] || fail_layout "canonical path map is empty"

# Fresh payloads and historical upgrades are distinct installation boundaries.
for profile in default developer; do
	layout_install_calls=0
	options=()
	[ "$profile" != developer ] || options=(--with-dev-sensors)
	fresh="${TMP_DIR}/fresh ${profile}"
	install_layout "$INSTALL" "$fresh" --write "${options[@]}" \
		|| fail_layout "fresh ${profile} installation"
	[ "$layout_install_calls" -eq 1 ] || fail_layout "fresh boundary repeated installation"
	manifests=("${ROOT}/scripts/install-harness.assets")
	[ "$profile" != developer ] || manifests+=("${ROOT}/scripts/install-harness.dev.assets")
	for manifest in "${manifests[@]}"; do
		while IFS= read -r asset; do
			case "$asset" in ""|\#*) continue ;; esac
			[ -f "${fresh}/${asset}" ] && [ ! -L "${fresh}/${asset}" ] \
				|| fail_layout "fresh ${profile} missing regular dependency ${asset}"
			expected_source="${ROOT}/${asset}"
			if [ "$asset" = .github/workflows/harness-smoke.yml ]; then
				expected_source="${ROOT}/profiles/adopter-smoke.yml"
			fi
			cmp -s "$expected_source" "${fresh}/${asset}" \
				|| fail_layout "fresh ${profile} changed dependency ${asset}"
		done <"$manifest"
	done
	while IFS=$'\t' read -r old canonical audience public; do
		if [ "$audience" = source-only ] || grep -Fxq "$canonical" "${ROOT}/tests/harness-dev-sensors.txt"; then
			[ ! -e "${fresh}/${canonical}" ] || fail_layout "fresh ${profile} installed source-only ${canonical}"
		fi
		if [ -z "$public" ]; then
			[ ! -e "${fresh}/${old}" ] || fail_layout "fresh ${profile} restored flat ${old}"
		fi
	done <"${TMP_DIR}/layout-moves"
	[ ! -e "${fresh}/optional/runtime-adapters" ] || fail_layout "fresh ${profile} restored Claude payload"
	mkdir -p "${fresh}/unrelated cwd"
	(cd "${fresh}/unrelated cwd" && "${fresh}/scripts/install-harness.sh" --help) >"$layout_log" 2>&1 \
		|| fail_layout "fresh ${profile} installer failed from unrelated cwd"
	(cd "${fresh}/unrelated cwd" && "${fresh}/scripts/scaffold-language.sh" go --write) >"$layout_log" 2>&1 \
		|| fail_layout "fresh ${profile} scaffolder failed from unrelated cwd"
	[ -f "${fresh}/profiles/go.profile.sh" ] && [ ! -e "${fresh}/unrelated cwd/profiles" ] \
		|| fail_layout "fresh ${profile} scaffolder lost installed root"
	mv "${fresh}/scripts/lib/reconcile-lib.sh" "${TMP_DIR}/reconcile.saved"
	if (cd "${fresh}/unrelated cwd" && "${fresh}/scripts/install-harness.sh" --help) >"$layout_log" 2>&1; then
		fail_layout "fresh ${profile} hid a missing installed dependency with source fallback"
	fi
	grep -Fq 'reconcile-lib.sh' "$layout_log" \
		|| fail_layout "fresh ${profile} missing-dependency diagnostic lost"
	mv "${TMP_DIR}/reconcile.saved" "${fresh}/scripts/lib/reconcile-lib.sh"
	printf 'fresh %s payload and no-source-fallback boundary passed\n' "$profile"
done

for profile in default developer claude; do
	layout_install_calls=0
	options=()
	case "$profile" in
		developer) options=(--with-dev-sensors) ;;
		claude) options=(--with-claude) ;;
	esac
	target="${TMP_DIR}/layout-${profile}"
	install_layout "${legacy_source}/scripts/install-harness.sh" "$target" --write "${options[@]}" \
		|| fail_layout "${profile} baseline installation"
	if [ "$profile" = claude ]; then options=(); fi
	mkdir -p "${target}/.claude"
	project_owned=(README.md AGENTS.md .env .env.example .claude/settings.json .claude/settings.local.json)
	for owned in "${project_owned[@]}"; do
		printf 'adopter-owned sentinel: %s\n' "$owned" >"${target}/${owned}"
	done
	[ -f "${target}/scripts/trace-lib.sh" ] && \
		[ ! -e "${target}/scripts/lib/trace-lib.sh" ] \
		|| fail_layout "${profile} fixture is not the actual previous layout"
	if [ "$profile" = default ]; then
		printf '\n# adopter trace customization\n' >>"${target}/scripts/trace-lib.sh"
		printf '\n# protected identity customization\n' >>"${target}/scripts/github-identity-lib.sh"
		printf 'scripts/github-identity-lib.sh\n' >"${target}/.harness-keep"
		awk -F '\t' '$2 != "scripts/issue-lib.sh"' "${target}/.harness-lock" >"${TMP_DIR}/lock"
		mv "${TMP_DIR}/lock" "${target}/.harness-lock"
	fi
	if [ "$profile" = claude ]; then
		modified=optional/runtime-adapters/claude-code-trace-hook.sh
		protected=optional/runtime-adapters/claude-code.md
		unknown=optional/runtime-adapters/tests/test_claude_hook_noop.sh
		printf '\n# adopter legacy hook customization\n' >>"${target}/${modified}"
		printf '%s\n' "$protected" >>"${target}/.harness-keep"
		awk -F '\t' -v path="$unknown" '$2 != path' "${target}/.harness-lock" >"${TMP_DIR}/lock"
		mv "${TMP_DIR}/lock" "${target}/.harness-lock"
	fi
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/before-dry"
	install_layout "$INSTALL" "$target" "${options[@]}" \
		|| fail_layout "${profile} dry-run"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/after-dry"
	cmp -s "${TMP_DIR}/before-dry" "${TMP_DIR}/after-dry" \
		|| fail_layout "${profile} dry-run changed files or ownership"

	status=0
	install_layout "$INSTALL" "$target" --update "${options[@]}" || status=$?
	if [ "$profile" = default ]; then
		[ "$status" -ne 0 ] || fail_layout "modified/unknown old paths must conflict"
		for old in scripts/trace-lib.sh scripts/issue-lib.sh; do
			grep -Fq "conflict ${old}" "$layout_log" \
				|| fail_layout "missing actionable conflict for ${old}"
			[ -f "${target}/${old}" ] && [ -f "${target}/${old}.rej" ] \
				|| fail_layout "conflicting old copy or rejection lost: ${old}"
		done
		grep -Fq 'ownership unknown' "$layout_log" || fail_layout "unknown ownership was not explained"
		grep -Fq 'adopter trace customization' "${target}/scripts/trace-lib.sh" \
			|| fail_layout "customized old library overwritten"
		grep -Fq 'protected identity customization' "${target}/scripts/github-identity-lib.sh" \
			|| fail_layout "protected old library overwritten"
		grep -Fq 'kept scripts/github-identity-lib.sh (.harness-keep)' "$layout_log" \
			|| fail_layout "protected old path was not acknowledged"
	elif [ "$profile" = claude ]; then
		[ "$status" -ne 0 ] || fail_layout "legacy modified/unknown bundle must conflict"
		for retired in "$modified" "$unknown"; do
			grep -Fq "conflict ${retired}" "$layout_log" || fail_layout "missing legacy conflict: ${retired}"
			[ -s "${target}/${retired}.rej" ] || fail_layout "missing actionable rejection: ${retired}"
			grep -q '^-' "${target}/${retired}.rej" || fail_layout "rejection lacks deletion patch"
		done
		grep -Fq 'ownership unknown' "$layout_log" || fail_layout "unknown legacy ownership not explained"
		grep -Fq 'adopter legacy hook customization' "${target}/${modified}" \
			|| fail_layout "legacy customization lost"
		for retired in "$protected" "$unknown"; do
			cmp -s "${legacy_source}/${retired}" "${target}/${retired}" \
				|| fail_layout "preserved legacy copy changed: ${retired}"
		done
		[ ! -e "${target}/${protected}.rej" ] || fail_layout "protected legacy copy received rejection"
	else
		[ "$status" -eq 0 ] || fail_layout "${profile} clean upgrade failed"
	fi
	while IFS=$'\t' read -r old canonical audience public; do
		case "$audience" in installed|source-only) ;; *) fail_layout "invalid audience ${audience}" ;; esac
		if [ "$audience" = source-only ] || grep -Fxq "$canonical" "${ROOT}/tests/harness-dev-sensors.txt"; then
			[ ! -e "${target}/${canonical}" ] || fail_layout "${profile} installed source-only ${canonical}"
		else
			[ -f "${target}/${canonical}" ] || fail_layout "${profile} missing canonical ${canonical}"
		fi
		if [ -n "$public" ]; then
			[ "$public" = "$old" ] && [ -x "${target}/${public}" ] \
				|| fail_layout "${profile} lost declared public entrypoint ${public}"
			continue
		fi
		if [ "$profile" = default ]; then
			case "$old" in scripts/trace-lib.sh|scripts/issue-lib.sh|scripts/github-identity-lib.sh) continue ;; esac
		fi
		[ ! -e "${target}/${old}" ] || fail_layout "${profile} left an owned clean old copy: ${old}"
	done <"${TMP_DIR}/layout-moves"
	if [ "$profile" = default ]; then
		# Conflicts must first transition to an acknowledged, successful update.
		install_layout "$INSTALL" "$target" --update "${options[@]}" \
			|| fail_layout "${profile} repeat update"
	fi
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/before-repeat"
	install_layout "${target}/scripts/install/install-harness.sh" "$target" --update "${options[@]}" \
		|| fail_layout "${profile} idempotent update"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/after-repeat"
	cmp -s "${TMP_DIR}/before-repeat" "${TMP_DIR}/after-repeat" \
		|| fail_layout "${profile} repeated update changed installed content"
	expected_calls=4
	[ "$profile" != default ] || expected_calls=5
	[ "$layout_install_calls" -eq "$expected_calls" ] \
		|| fail_layout "${profile} performed ${layout_install_calls} installer calls; expected ${expected_calls}"
	if [ "$profile" = claude ]; then
		while IFS= read -r retired; do
			case "$retired" in "" | \#*) continue ;; esac
			case "$retired" in
				"$modified"|"$protected"|"$unknown")
					[ -f "${target}/${retired}" ] || fail_layout "preserved legacy copy vanished: ${retired}"
					continue ;;
			esac
			[ ! -e "${target}/${retired}" ] || fail_layout "owned legacy bundle was not retired: ${retired}"
		done <"${legacy_source}/scripts/install-harness.claude.assets"
	fi
	for owned in "${project_owned[@]}"; do
		[ "$(cat "${target}/${owned}")" = "adopter-owned sentinel: ${owned}" ] \
			|| fail_layout "${profile} changed project-owned ${owned}"
	done

	mkdir -p "${target}/unrelated/nested"
	for entry in scripts/scaffold-language.sh scripts/install/scaffold-language.sh; do
		(cd "${target}/unrelated/nested" && "${target}/${entry}" go --write) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed scaffolder ${entry}"
		[ -f "${target}/profiles/go.profile.sh" ] && [ -f "${target}/.copilot/instructions/go.instructions.md" ] \
			|| fail_layout "${profile} installed scaffolder wrote outside its source"
		bash -n "${target}/profiles/go.profile.sh" || fail_layout "${profile} generated invalid profile"
	done
	rm "${target}/profiles/go.profile.sh" "${target}/.copilot/instructions/go.instructions.md"
	git -C "$target" init -q -b main
	git -C "$target" config user.name "Harness Test"
	git -C "$target" config user.email "harness-test@example.invalid"
	git -C "$target" config commit.gpgsign false
	mkdir -p "${TMP_DIR}/preflight-bin" "${target}/tests/scripts/lifecycle"
	cat >"${TMP_DIR}/preflight-bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
	issue) printf 'Installed startup fixture\n' ;;
	pr)
		case "${2:-}" in
			view)
				case "$*" in
					*state,mergeCommit*) printf 'MERGED\tdeadbeef0001cafe\n' ;;
					*) printf '81\n' ;;
				esac ;;
			checks)
				if [ "${INSTALLED_CI_GREEN:-0}" = 1 ]; then
					printf 'harness-smoke\tpass\t1m\n'
				else
					printf 'harness-smoke\tpending\t0\n'
					exit 8
				fi ;;
			merge) printf '%s\n' "$*" >>"${INSTALLED_MERGE_LOG:?}" ;;
			list)
				printf '[{"headRefName":"feature/issue-%s-installed-start","state":"MERGED","mergedAt":"2026-05-01T12:30:00Z","number":%s}]\n' \
					"${INSTALLED_FINISH_ISSUE:?}" "$INSTALLED_FINISH_ISSUE" ;;
			*) exit 1 ;;
		esac ;;
	*) exit 1 ;;
esac
SH
	printf '#!/usr/bin/env bash\nexit 1\n' >"${TMP_DIR}/preflight-bin/az"
	chmod +x "${TMP_DIR}/preflight-bin/gh" "${TMP_DIR}/preflight-bin/az"
	for entry in scripts/init.sh scripts/lifecycle/init.sh; do
		(cd "${target}/unrelated/nested" && REQUIRE_AZ=0 \
			PATH="${TMP_DIR}/preflight-bin:${PATH}" "${target}/${entry}") \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed preflight ${entry}"
		grep -q 'docs-only project surface detected' "$layout_log" \
			|| fail_layout "${profile} preflight used the wrong project surface"
	done
	# Runtime evidence is local state, not a source change for the installed probe.
	printf '/.copilot-tracking/\n/.worktrees/\n' >>"${target}/.git/info/exclude"
	printf '9.8.7-layout\n' >"${target}/VERSION"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${target}/tests/scripts/lifecycle/test_installed_probe.sh"
	git -C "$target" add .
	git -C "$target" commit -qm 'test: upgraded installed layout'
	for entry in scripts/start-issue.sh scripts/lifecycle/start-issue.sh; do
		(cd "${target}/unrelated/nested" && REQUIRE_AZ=0 \
			PATH="${TMP_DIR}/preflight-bin:${PATH}" "${target}/${entry}" ISSUE=81 SLUG=installed-start) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed startup ${entry}"
		[ -f "${target}/.worktrees/issue-81/.copilot-tracking/issues/issue-81/feature_list.json" ] \
			|| fail_layout "${profile} installed startup omitted its scaffold"
		if (cd "${target}/unrelated/nested" && \
			PATH="${TMP_DIR}/preflight-bin:${PATH}" "${target}/.worktrees/issue-81/${entry}" 82 SLUG=refused) \
			>"$layout_log" 2>&1; then
			fail_layout "${profile} installed linked-worktree startup was not refused"
		fi
		grep -q 'main checkout, not from a worktree' "$layout_log" \
			|| fail_layout "${profile} installed startup lost its checkout guard"
		[ ! -e "${target}/.worktrees/issue-82" ] || fail_layout "${profile} refused startup created state"
	done
	linked="${target}/.worktrees/issue-81"
	mkdir -p "${linked}/nested/cwd"
	checker_fixture="${linked}/.copilot-tracking/trace-fixture"
	mkdir -p "$checker_fixture"
	cp "${linked}/.copilot-tracking/issues/issue-81/progress.md" "${checker_fixture}/progress.md"
	for entry in scripts/check-trace-consistency.sh scripts/trace/check-trace-consistency.sh; do
		(cd "${linked}/nested/cwd" && "${linked}/${entry}" 81) >"$layout_log" 2>&1 \
			|| fail_layout "${profile} installed linked checker ${entry}"
		grep -Fq '0 violation(s)' "$layout_log" || fail_layout "${profile} checker omitted validation"
		cp "${target}/.copilot-tracking/issues/issue-81/trace.jsonl" "${checker_fixture}/trace.jsonl"
		(cd "${linked}/nested/cwd" && "${linked}/${entry}" ../../.copilot-tracking/trace-fixture/trace.jsonl) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed relative-path checker ${entry}"
		printf 'invalid fixture JSON\n' >>"${checker_fixture}/trace.jsonl"
		checker_rc=0
		(cd "${linked}/nested/cwd" && "${linked}/${entry}" ../../.copilot-tracking/trace-fixture/trace.jsonl) \
			>"$layout_log" 2>&1 || checker_rc=$?
		if [ "$checker_rc" -ne 1 ] || ! grep -Fq 'invalid_json' "$layout_log"; then
			fail_layout "${profile} installed checker lost schema finding/status ${entry}"
		fi
	done
	trace="${target}/.copilot-tracking/issues/issue-81/trace.jsonl"
	progress="${linked}/.copilot-tracking/issues/issue-81/progress.md"
	for prefix in scripts scripts/trace; do
		(cd "${linked}/nested/cwd" && TRACE_REVIEW_MODE=full TRACE_REVIEW_EVENT_ID=installed-review \
			"${linked}/${prefix}/log-handback.sh" conductor review_verdict installed-probe pass \
			"installed review from ${prefix}") >"$layout_log" 2>&1 \
			|| fail_layout "${profile} installed writer ${prefix}"
		jq -e -s --arg summary "installed review from ${prefix}" --arg sha "$(git -C "$linked" rev-parse HEAD)" \
			'last | .["harness.summary"] == $summary and .["harness.review_mode"] == "full"
			and .["harness.review_event_id"] == "installed-review" and .["harness.reviewed_sha"] == $sha' \
			"$trace" >/dev/null || fail_layout "${profile} installed writer lost attribution"
		grep -Fq "installed review from ${prefix}" "$progress" \
			|| fail_layout "${profile} installed writer did not render Action Log"
		before_trace="$(shasum -a 256 "$trace")"
		before_progress="$(shasum -a 256 "$progress")"
		writer_rc=0
		(cd "${linked}/nested/cwd" && "${linked}/${prefix}/log-handback.sh" \
			conductor review_verdict installed-probe fail invalid) >"$layout_log" 2>&1 || writer_rc=$?
		if [ "$writer_rc" -ne 1 ] || ! grep -Fq TRACE_ACTIONABLE "$layout_log"; then
			fail_layout "${profile} installed writer lost rejection/status"
		fi
		[ "$(shasum -a 256 "$trace")" = "$before_trace" ] \
			&& [ "$(shasum -a 256 "$progress")" = "$before_progress" ] \
			|| fail_layout "${profile} rejected installed write modified artifacts"
		cp "$trace" "${checker_fixture}/trace.jsonl"
		printf '# Installed renderer\n\n## Action Log\n\n' >"${checker_fixture}/progress.md"
		(cd "${linked}/nested/cwd" && "${linked}/${prefix}/render-action-log.sh" \
			../../.copilot-tracking/trace-fixture/trace.jsonl) >"$layout_log" 2>&1 \
			|| fail_layout "${profile} installed explicit-path renderer"
		grep -Fq "installed review from ${prefix}" "${checker_fixture}/progress.md" \
			|| fail_layout "${profile} installed explicit renderer did not materialize spans"
	done
	for entry in scripts/create-pr.sh scripts/lifecycle/create-pr.sh; do
		(cd "${linked}/nested/cwd" && PATH="${TMP_DIR}/preflight-bin:${PATH}" "${linked}/${entry}" --help) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed publication help ${entry}"
		grep -q -- '--prepare' "$layout_log" || fail_layout "${profile} publication help lost preparation"
		if (cd "${linked}/nested/cwd" && PATH="${TMP_DIR}/preflight-bin:${PATH}" "${linked}/${entry}" \
			--title 'Unapproved installed candidate' --body 'Must not publish') >"$layout_log" 2>&1; then
			fail_layout "${profile} installed publication bypassed review"
		fi
		grep -q 'current HEAD has not been approved by the review gate' "$layout_log" \
			|| fail_layout "${profile} installed publication lost its review guard"
	done
	for entry in scripts/merge-pr.sh scripts/lifecycle/merge-pr.sh; do
		merge_log="${TMP_DIR}/merge-${profile}.log"
		rm -f "$merge_log"
		if (cd "${linked}/nested/cwd" && PATH="${TMP_DIR}/preflight-bin:${PATH}" \
			INSTALLED_MERGE_LOG="$merge_log" "${linked}/${entry}" --squash) >"$layout_log" 2>&1; then
			fail_layout "${profile} installed merge bypassed pending CI"
		fi
		if [ -e "$merge_log" ] || ! grep -q 'checks are not green' "$layout_log"; then
			fail_layout "${profile} pending CI did not prevent merge"
		fi
		(cd "${linked}/nested/cwd" && PATH="${TMP_DIR}/preflight-bin:${PATH}" \
			INSTALLED_MERGE_LOG="$merge_log" INSTALLED_CI_GREEN=1 "${linked}/${entry}" --squash) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed merge failed despite green checks"
		if ! grep -q 'pr merge 81 --squash' "$merge_log" || ! grep -q 'PR #81 merged' "$layout_log"; then
			fail_layout "${profile} installed merge lost flags or authoritative confirmation"
		fi
	done
	finish_issue=81
	for entry in scripts/finish-issue.sh scripts/lifecycle/finish-issue.sh; do
		if [ "$finish_issue" = 82 ]; then
			(cd "${target}/unrelated/nested" && REQUIRE_AZ=0 \
				PATH="${TMP_DIR}/preflight-bin:${PATH}" "${target}/scripts/start-issue.sh" 82 SLUG=installed-start) \
				>"$layout_log" 2>&1 || fail_layout "${profile} canonical closeout setup"
		fi
		issue_dir=".copilot-tracking/issues/issue-${finish_issue}"
		worktree="${target}/.worktrees/issue-${finish_issue}"
		printf '%s\n' '{"features":[{"id":"done","title":"Installed probe","steps":[],"passes":true,"regression_sensor":"tests/scripts/lifecycle/test_installed_probe.sh","e2e_sensor":"tests/scripts/lifecycle/test_installed_probe.sh","verification":"installed probe","blocked_on":null}]}' \
			>"${worktree}/${issue_dir}/feature_list.json"
		printf '# Installed issue %s\n\nStatus: implementation complete.\n\n## Action Log\n' "$finish_issue" \
			>"${worktree}/${issue_dir}/progress.md"
		printf '{"schema_version":1,"timestamp":"2026-05-01T10:00:00Z","span":"agent","harness.issue":%s,"harness.version":"test","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"code-review-subagent","harness.lifecycle_step":"review_verdict","harness.feature_id":"done","harness.outcome":"pass"}\n' \
			"$finish_issue" >>"${target}/${issue_dir}/trace.jsonl"
		(cd "${target}/unrelated/nested" && PATH="${TMP_DIR}/preflight-bin:${PATH}" \
			INSTALLED_FINISH_ISSUE="$finish_issue" "${target}/${entry}" "ISSUE=${finish_issue}" SLUG=installed-start) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed closeout ${entry}"
		[ ! -e "$worktree" ] || fail_layout "${profile} closeout left its worktree"
		grep -q '^Conclusion: merged; review verdict: APPROVED.' "${target}/${issue_dir}/progress.md" \
			|| fail_layout "${profile} closeout lost its durable conclusion"
		jq -se '[.[] | select(.span == "lifecycle" and .["harness.lifecycle_step"] == "finish" and .["harness.worktree_removed"] == "true")] | length == 1' \
			"${target}/${issue_dir}/trace.jsonl" >/dev/null || fail_layout "${profile} closeout lost its terminal evidence"
		finish_issue=82
	done
	for runner in scripts/run-sensors.sh scripts/validation/run-sensors.sh; do
		(cd "${target}/unrelated/nested" && "${target}/${runner}" green \
			--declared tests/scripts/lifecycle/test_installed_probe.sh --diff HEAD) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed ${runner}"
		grep -q 'scope=scoped ran=1 failed=0$' "$layout_log" \
			|| fail_layout "${profile} runner did not use installed sensor selection"
	done
	(
		cd "${target}/unrelated/nested"
		# shellcheck source=/dev/null
		source "${target}/scripts/lib/trace-lib.sh"
		TRACE_ISSUE=91 trace_span tool "gen_ai.tool.name=installed-layout"
	)
	jq -se 'length == 1 and .[0]["harness.version"] == "9.8.7-layout"' \
		"${target}/.copilot-tracking/issues/issue-91/trace.jsonl" >/dev/null \
		|| fail_layout "${profile} emitter used source identity instead of installed VERSION"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${target}/tests/scripts/lifecycle/test_installed_probe.sh"
	if (cd "${target}/unrelated/nested" && "${target}/scripts/run-sensors.sh" green \
		--declared tests/scripts/lifecycle/test_installed_probe.sh --diff HEAD) >"$layout_log" 2>&1; then
		fail_layout "${profile} ignored the installed nested failure"
	fi
	grep -q '^FAIL tests/scripts/lifecycle/test_installed_probe.sh$' "$layout_log" \
		|| fail_layout "${profile} failure did not name the installed sensor"
	grep -q 'scope=scoped ran=1 failed=1$' "$layout_log" \
		|| fail_layout "${profile} targeted failure selected unrelated sensors"
done
# A modified installed contract must not turn migration candidates into paths
# outside the target, even before ownership checks run.
sed 's|from: scripts/affected-sensors.sh|from: scripts/../../outside|' \
	"${target}/docs/harness-contract.yml" >"${TMP_DIR}/unsafe-contract"
mv "${TMP_DIR}/unsafe-contract" "${target}/docs/harness-contract.yml"
printf 'outside sentinel\n' >"${TMP_DIR}/outside"
if "${target}/scripts/install-harness.sh" "${TMP_DIR}/unsafe-map-target" --write \
	>"$layout_log" 2>&1; then
	fail_layout "unsafe migration path accepted"
fi
grep -Fq 'unsafe excluded asset path' "$layout_log" \
	|| fail_layout "unsafe migration path did not explain the refusal"
[ "$(cat "${TMP_DIR}/outside")" = 'outside sentinel' ] && \
	[ ! -e "${TMP_DIR}/unsafe-map-target/VERSION" ] \
	|| fail_layout "unsafe migration map wrote files before refusal"
printf 'previous-layout upgrades preserve ownership and execute installed categories\n'
