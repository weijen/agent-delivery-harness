#!/usr/bin/env bash
# Regression and e2e sensor (issue #312): adopter installs omit harness-dev
# sensors by default, prune clean legacy copies, and expose an explicit opt-in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

(
layout_log="${TMP_DIR}/layout-upgrade.log"
fail_layout() {
	[ ! -f "$layout_log" ] || cat "$layout_log" >&2
	printf 'FAIL: layout upgrade: %s\n' "$*" >&2
	exit 1
}
legacy_source="${TMP_DIR}/previous-layout"
mkdir -p "$legacy_source"
# The pre-layout release is an explicit reusable-asset fixture, not a checkout
# archive: project-owned environment files and local bindings are not inputs.
git -C "$ROOT" archive v0.45.2 scripts profiles tests .copilot docs schemas optional VERSION \
	.github/harness-identity.env.example | tar -x -C "$legacy_source"
awk '
	/^layout_moves:/ { selected=1; next }
	selected && /^[^ #]/ { exit }
	selected && /^  - from:/ { old=$3 }
	selected && /^    to:/ { print old "\t" $2 }
' "${ROOT}/docs/harness-contract.yml" >"${TMP_DIR}/layout-moves"
[ -s "${TMP_DIR}/layout-moves" ] || fail_layout "canonical path map is empty"

for profile in default developer claude; do
	options=()
	case "$profile" in
		developer) options=(--with-dev-sensors) ;;
		claude) options=(--with-claude) ;;
	esac
	target="${TMP_DIR}/layout-${profile}"
	"${legacy_source}/scripts/install-harness.sh" "$target" --write "${options[@]}" \
		>"$layout_log" 2>&1 || fail_layout "${profile} baseline installation"
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
	find "$target" -type f -exec shasum -a 256 {} \; | sort >"${TMP_DIR}/before-dry"
	"$INSTALL" "$target" "${options[@]}" >"$layout_log" 2>&1 \
		|| fail_layout "${profile} dry-run"
	find "$target" -type f -exec shasum -a 256 {} \; | sort >"${TMP_DIR}/after-dry"
	cmp -s "${TMP_DIR}/before-dry" "${TMP_DIR}/after-dry" \
		|| fail_layout "${profile} dry-run changed files or ownership"

	status=0
	"$INSTALL" "$target" --update "${options[@]}" >"$layout_log" 2>&1 || status=$?
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
	else
		[ "$status" -eq 0 ] || fail_layout "${profile} clean upgrade failed"
	fi
	while IFS=$'\t' read -r old canonical; do
		[ -f "${target}/${canonical}" ] || fail_layout "${profile} missing canonical ${canonical}"
		[ "$old" != scripts/run-sensors.sh ] || continue
		if [ "$profile" = default ]; then
			case "$old" in scripts/trace-lib.sh|scripts/issue-lib.sh|scripts/github-identity-lib.sh) continue ;; esac
		fi
		[ ! -e "${target}/${old}" ] || fail_layout "${profile} left an owned clean old copy: ${old}"
	done <"${TMP_DIR}/layout-moves"
	"$INSTALL" "$target" --update "${options[@]}" >"$layout_log" 2>&1 \
		|| fail_layout "${profile} repeat update"
	find "$target" -type f -exec shasum -a 256 {} \; | sort >"${TMP_DIR}/before-repeat"
	"$INSTALL" "$target" --update "${options[@]}" >"$layout_log" 2>&1 \
		|| fail_layout "${profile} idempotent update"
	find "$target" -type f -exec shasum -a 256 {} \; | sort >"${TMP_DIR}/after-repeat"
	cmp -s "${TMP_DIR}/before-repeat" "${TMP_DIR}/after-repeat" \
		|| fail_layout "${profile} repeated update changed installed content"

	mkdir -p "${target}/unrelated/nested"
	git -C "$target" init -q -b main
	git -C "$target" config user.name "Harness Test"
	git -C "$target" config user.email "harness-test@example.invalid"
	git -C "$target" config commit.gpgsign false
	printf '9.8.7-layout\n' >"${target}/VERSION"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${target}/tests/scripts/validation/test_installed_probe.sh"
	git -C "$target" add .
	git -C "$target" commit -qm 'test: upgraded installed layout'
	for runner in scripts/run-sensors.sh scripts/validation/run-sensors.sh; do
		(cd "${target}/unrelated/nested" && "${target}/${runner}" green \
			--declared tests/scripts/validation/test_installed_probe.sh --diff HEAD) \
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
	printf '#!/usr/bin/env bash\nexit 1\n' >"${target}/tests/scripts/validation/test_installed_probe.sh"
	if (cd "${target}/unrelated/nested" && "${target}/scripts/run-sensors.sh" green \
		--declared tests/scripts/validation/test_installed_probe.sh --diff HEAD) >"$layout_log" 2>&1; then
		fail_layout "${profile} ignored the installed nested failure"
	fi
	grep -q '^FAIL tests/scripts/validation/test_installed_probe.sh$' "$layout_log" \
		|| fail_layout "${profile} failure did not name the installed sensor"
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
)

if awk '/^HARNESS_ASSETS=\(/ { selected=1; next } selected && /^\)/ { exit } selected { print }' \
	"$INSTALL" | grep -Eq '(^|[[:space:]])\.env\.example([[:space:]]|$)'; then
	echo "project-owned environment example must not be an installer asset"
	exit 1
fi

"$INSTALL" --help >"$OUT"
grep -qF -- "--with-dev-sensors" "$OUT" || {
	cat "$OUT"
	echo "installer help does not expose the dev-sensor opt-in"
	exit 1
}

default_target="${TMP_DIR}/default"
"$INSTALL" "$default_target" --write >"$OUT" 2>&1
[ ! -e "${default_target}/.env.example" ] || {
	echo "default install shipped project-owned environment configuration"
	exit 1
}
for excluded in scripts/sync-version.sh scripts/check-install-harness-tombstones.sh \
	docs/RELEASING.md docs/evaluation docs/archive docs/runtime-adapters \
	tests/evals/bin/run-evals.sh tests/evals/bin/run-l0-suite.sh tests/evals/manifests \
	tests/evals/fixtures tests/evals/baselines tests/evals/scorecards; do
	[ ! -e "${default_target}/${excluded}" ] || {
		echo "default install shipped maintainer or optional asset: ${excluded}"
		exit 1
	}
done
[ -f "${default_target}/scripts/install-harness.assets" ] || {
	echo "default install omitted its explicit asset manifest"
	exit 1
}
cmp -s "${ROOT}/profiles/adopter-smoke.yml" \
	"${default_target}/.github/workflows/harness-smoke.yml" || {
	echo "default install did not select the adopter smoke workflow"
	exit 1
}
[ -f "${default_target}/tests/harness-dev-sensors.txt" ] || {
	echo "default install did not ship the sensor profile manifest"
	exit 1
}
[ -f "${default_target}/tests/scripts/test_harness_contract.sh" ] || {
	echo "default install omitted a core lifecycle sensor"
	exit 1
}
[ ! -e "${default_target}/tests/scripts/test_release_workflow.sh" ] || {
	echo "default install shipped a harness-dev release sensor"
	exit 1
}
[ ! -e "${default_target}/tests/scripts/test_install_harness_symlinked_parent.sh" ] || {
	echo "default install shipped the harness-dev symlinked-parent sensor"
	exit 1
}
if find "${default_target}/tests/meta" -type f -name 'test_*.sh' 2>/dev/null | grep -q .; then
	echo "default install shipped harness-dev meta sensors"
	exit 1
fi
if ! "${default_target}/scripts/install-harness.sh" "$default_target" >"$OUT" 2>&1; then
	cat "$OUT"
	echo "installed adopter-profile installer is not self-contained"
	exit 1
fi

python3 - "$default_target" <<'PY'
import pathlib
import re
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1])
for directory in ("docs", ".copilot", "profiles"):
    for path in (root / directory).rglob("*.md"):
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            url = target.split()[0]
            if url.startswith(("#", "https:", "http:", "mailto:", "<")):
                continue
            local = urllib.parse.unquote(url.split("#")[0])
            if local and not (path.parent / local).exists():
                raise SystemExit(f"installed guidance link is broken: {path.relative_to(root)} -> {target}")
PY

# Newly colocated source assets must not enter an explicit default selection.
mkdir -p "${default_target}/docs/evaluation" "${default_target}/tests/fixtures/unclassified"
printf '#!/usr/bin/env bash\nexit 0\n' >"${default_target}/scripts/unclassified-maintenance.sh"
printf 'unclassified research\n' >"${default_target}/docs/evaluation/unclassified.md"
printf 'unclassified data\n' >"${default_target}/tests/fixtures/unclassified/data.txt"
probe_target="${TMP_DIR}/manifest-probe"
mkdir -p "${probe_target}/docs" "${probe_target}/.claude"
for owned in README.md AGENTS.md docs/tech-debt-tracker.md .claude/settings.json; do
	printf 'adopter-owned sentinel\n' >"${probe_target}/${owned}"
done
"${default_target}/scripts/install-harness.sh" "$probe_target" --write >"$OUT" 2>&1 || {
	cat "$OUT"
	echo "explicit installed manifest is not self-contained"
	exit 1
}
for excluded in scripts/unclassified-maintenance.sh docs/evaluation/unclassified.md \
	tests/fixtures/unclassified/data.txt; do
	[ ! -e "${probe_target}/${excluded}" ] || {
		echo "unclassified asset leaked into default payload: ${excluded}"
		exit 1
	}
done
for owned in README.md AGENTS.md docs/tech-debt-tracker.md .claude/settings.json; do
	[ "$(cat "${probe_target}/${owned}")" = "adopter-owned sentinel" ] || {
		echo "installer changed adopter-owned ${owned}"
		exit 1
	}
done
cp "${default_target}/scripts/install-harness.assets" "${TMP_DIR}/manifest.before"
printf '../outside\n' >>"${default_target}/scripts/install-harness.assets"
if "${default_target}/scripts/install-harness.sh" "${TMP_DIR}/invalid-target" --write >"$OUT" 2>&1; then
	echo "unsafe manifest path was accepted"
	exit 1
fi
if ! grep -qF 'unsafe adopter asset path' "$OUT" || [ -e "${TMP_DIR}/invalid-target" ]; then
	cat "$OUT"
	echo "invalid selection must fail before creating the target"
	exit 1
fi
cp "${TMP_DIR}/manifest.before" "${default_target}/scripts/install-harness.assets"
mv "${default_target}/scripts/init.sh" "${TMP_DIR}/init.saved"
if "${default_target}/scripts/install-harness.sh" "${TMP_DIR}/missing-target" --write >"$OUT" 2>&1; then
	echo "missing required source asset was accepted"
	exit 1
fi
grep -qF 'adopter asset missing from source: scripts/init.sh' "$OUT" || {
	cat "$OUT"
	echo "missing asset did not produce an actionable diagnostic"
	exit 1
}
[ ! -e "${TMP_DIR}/missing-target" ] || {
	echo "missing source dependency partially installed a target"
	exit 1
}
mv "${TMP_DIR}/init.saved" "${default_target}/scripts/init.sh"

# An old lock cannot make project-owned configuration eligible for deletion.
printf 'adopter-owned configuration fixture\n' >"${TMP_DIR}/owned-config"
cp "${TMP_DIR}/owned-config" "${TMP_DIR}/owned-config.before"
ln -s "${TMP_DIR}/owned-config" "${default_target}/.env.example"
printf '%064d\t.env.example\n' 0 >>"${default_target}/.harness-lock"
for mode in dry write update; do
	args=("$default_target")
	[ "$mode" = dry ] || args+=("--${mode}")
	"$INSTALL" "${args[@]}" >"$OUT" 2>&1 || {
		cat "$OUT"
		echo "project-owned environment configuration blocked ${mode}"
		exit 1
	}
	if [ ! -L "${default_target}/.env.example" ] || \
		! cmp -s "${TMP_DIR}/owned-config.before" "${TMP_DIR}/owned-config"; then
		echo "installer changed existing project-owned environment configuration"
		exit 1
	fi
done
if grep -qF $'\t.env.example' "${default_target}/.harness-lock"; then
	echo "installer retained ownership of project-owned environment configuration"
	exit 1
fi

upgrade_target="${TMP_DIR}/upgrade"
"$INSTALL" "$upgrade_target" --write >"$OUT" 2>&1
# Model the preceding broad payload; portable developer mode no longer ships it.
for legacy in tests/scripts/test_release_workflow.sh \
	tests/scripts/test_install_harness_symlinked_parent.sh \
	tests/scripts/test_init_gates.sh tests/meta/test_agent_model_pins.sh; do
	mkdir -p "${upgrade_target}/$(dirname "$legacy")"
	cp "${ROOT}/${legacy}" "${upgrade_target}/${legacy}"
	digest="$(shasum -a 256 "${upgrade_target}/${legacy}" | awk '{print $1}')"
	printf '%s\t%s\n' "$digest" "$legacy" >>"${upgrade_target}/.harness-lock"
done
printf '\n# adopter customization\n' >>"${upgrade_target}/tests/scripts/test_init_gates.sh"
if "$INSTALL" "$upgrade_target" --write >"$OUT" 2>&1; then
	cat "$OUT"
	echo "default upgrade must report a modified excluded sensor"
	exit 1
fi
[ ! -e "${upgrade_target}/tests/scripts/test_release_workflow.sh" ] || {
	echo "default upgrade left an unmodified harness-dev sensor"
	exit 1
}
[ ! -e "${upgrade_target}/tests/scripts/test_install_harness_symlinked_parent.sh" ] || {
	echo "default upgrade left the unmodified symlinked-parent sensor"
	exit 1
}
grep -qF "adopter customization" "${upgrade_target}/tests/scripts/test_init_gates.sh" || {
	echo "default upgrade removed a modified harness-dev sensor"
	exit 1
}
grep -qF "preserving modified harness-dev sensor tests/scripts/test_init_gates.sh" "$OUT" || {
	cat "$OUT"
	echo "default upgrade did not report the preserved modified sensor"
	exit 1
}

# --update must preserve a modified excluded sensor as a three-way conflict.
if "$INSTALL" "$upgrade_target" --update >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--update on a modified excluded sensor must fail visibly"
	exit 1
fi
grep -qF "conflict tests/scripts/test_init_gates.sh" "$OUT" || {
	cat "$OUT"
	echo "--update did not report the modified harness-dev conflict"
	exit 1
}
[ -e "${upgrade_target}/tests/scripts/test_init_gates.sh" ] || {
	echo "--update removed the modified harness-dev sensor"
	exit 1
}
[ -f "${upgrade_target}/tests/scripts/test_init_gates.sh.rej" ] || {
	echo "--update did not emit the rejected harness-dev deletion"
	exit 1
}

printf 'install-harness adopter profile sensor passed\n'

(

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

TARGET="${TMP_DIR}/target"
mkdir -p "$TARGET"
"$INSTALL" "$TARGET" --write >"${TMP_DIR}/install.out" 2>&1 \
  || {
    cat "${TMP_DIR}/install.out" >&2
    fail "installer must write the adopter identity template"
  }

TEMPLATE="${TARGET}/.github/harness-identity.env.example"
[ -f "$TEMPLATE" ] || fail "installer must ship harness-identity.env.example"
[ ! -e "${TARGET}/.github/harness-identity.env" ] \
  || fail "installer must not propagate the source repository binding"
[ -f "${TARGET}/scripts/lib/github-identity-lib.sh" ] \
  || fail "installer must ship the shared identity helper"
grep -Fq 'HARNESS_GH_ACCOUNT=your-github-account' "$TEMPLATE" \
  || fail "template must show a placeholder account"
if grep -Eq 'weijen|11629' "$TEMPLATE"; then
  fail "template must not contain this repository's account identity"
fi

grep -Fq '.github/harness-identity.env' "${ROOT}/docs/getting-started.md" \
  || fail "getting-started must document repository identity binding"
grep -Fq "never runs \`gh auth switch\`" "${ROOT}/docs/getting-started.md" \
  || fail "documentation must state the non-mutating global-account contract"
if git -C "$ROOT" ls-files --error-unmatch .github/harness-identity.env >/dev/null 2>&1; then
	fail "the source repository must not track a machine-local identity binding"
fi

identity_guide="$(awk '
	/^### Bind the repository/ { capture = 1; next }
	capture && /^## / { exit }
	capture { print }
' "${TARGET}/docs/getting-started.md" | tr '\n' ' ')"
for identity_rule in 'machine-local' 'untracked' 'gitignored'; do
	printf '%s\n' "$identity_guide" | grep -qiF "$identity_rule" \
		|| fail "installed identity guide must describe the binding as ${identity_rule}"
done
if printf '%s\n' "$identity_guide" | grep -qiE 'may be tracked|binding is repository configuration'; then
	fail "installed guide must not authorize committing a machine-local identity"
fi

BOUND_TARGET="${TMP_DIR}/bound-target"
mkdir -p "${BOUND_TARGET}/.github"
git -C "$BOUND_TARGET" init -q -b main
git -C "$BOUND_TARGET" remote add origin https://github.com/example/adopter.git
printf '# Adopter ignore rules\n' >"${BOUND_TARGET}/.gitignore"
cat >"${BOUND_TARGET}/.github/harness-identity.env" <<'EOF'
HARNESS_GH_ACCOUNT=adopter-account
HARNESS_GIT_NAME=Adopter Author
HARNESS_GIT_EMAIL=123+adopter-account@users.noreply.github.com
EOF
"$INSTALL" "$BOUND_TARGET" --write >"${TMP_DIR}/bound-install.out" 2>&1 \
  || {
    cat "${TMP_DIR}/bound-install.out" >&2
    fail "installer must apply an existing target binding"
  }
[ "$(git -C "$BOUND_TARGET" config --local user.name)" = "Adopter Author" ] \
  || fail "installer must apply target-local Git author identity"
[ "$(git -C "$BOUND_TARGET" remote get-url origin)" = \
  "https://adopter-account@github.com/example/adopter.git" ] \
  || fail "installer must route the target origin through its own bound account"

git -C "$BOUND_TARGET" check-ignore -q .github/harness-identity.env \
	|| fail "installed identity ignore rule must agree with the guide"
if git -C "$BOUND_TARGET" check-ignore -q .github/harness-identity.env.example; then
	fail "the placeholder identity example must remain trackable"
fi

printf 'installer identity template contract honored\n'
)

(

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT}/tests/harness-dev-sensors.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ -f "$MANIFEST" ] || {
	echo "harness-dev sensor manifest missing: $MANIFEST"
	exit 1
}

grep -Ev '^[[:space:]]*(#|$)' "$MANIFEST" >"${TMP_DIR}/entries"
[ -s "${TMP_DIR}/entries" ] || {
	echo "harness-dev sensor manifest has no entries"
	exit 1
}
if ! diff -u "${TMP_DIR}/entries" <(sort -u "${TMP_DIR}/entries"); then
	echo "harness-dev sensor manifest must be sorted and unique"
	exit 1
fi

while IFS= read -r pattern; do
	case "$pattern" in
	tests/scripts/test_*.sh | tests/meta/test_*.sh) ;;
	*)
		echo "invalid harness-dev sensor pattern: $pattern"
		exit 1
		;;
	esac

	matches=()
	while IFS= read -r match; do
		matches+=("$match")
	done < <(cd "$ROOT" && compgen -G "$pattern" | sort)
	[ "${#matches[@]}" -gt 0 ] || {
		echo "harness-dev sensor pattern matches nothing: $pattern"
		exit 1
	}
done <"${TMP_DIR}/entries"

while IFS= read -r sensor; do
	grep -Eq '^[[:space:]]*[^#].*--with-dev-sensors' "${ROOT}/${sensor}" \
		|| continue

	classified=false
	while IFS= read -r pattern; do
		# shellcheck disable=SC2254 # Manifest entries are intentional glob patterns.
		case "$sensor" in
		$pattern)
			classified=true
			break
			;;
		esac
	done <"${TMP_DIR}/entries"
	[ "$classified" = true ] || {
		echo "dev-fixture sensor must be harness-dev: $sensor"
		exit 1
	}
done < <(cd "$ROOT" && compgen -G 'tests/scripts/test_*.sh' | sort)

required=(
	'tests/meta/test_*.sh'
	tests/scripts/test_init_gates.sh
	tests/scripts/test_install_harness_symlinked_parent.sh
	tests/scripts/test_release_workflow.sh
	tests/scripts/test_eval_manifest_validator.sh
)
for pattern in "${required[@]}"; do
	grep -qxF "$pattern" "${TMP_DIR}/entries" || {
		echo "required harness-dev classification missing: $pattern"
		exit 1
	}
done

core=(
	tests/scripts/test_harness_contract.sh
	tests/scripts/test_install_harness.sh
	tests/scripts/test_issue_scaffold.sh
	tests/scripts/validation/test_review_gate.sh
	tests/scripts/test_trace_lifecycle_e2e.sh
)
for sensor in "${core[@]}"; do
	while IFS= read -r pattern; do
		# shellcheck disable=SC2254 # Manifest entries are intentional glob patterns.
		case "$sensor" in
		$pattern)
			echo "core lifecycle sensor must not be harness-dev: $sensor"
			exit 1
			;;
		esac
	done <"${TMP_DIR}/entries"
done

printf 'harness-dev sensor manifest passed\n'
)

(

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
TARGET="${TMP_DIR}/installed"
INSTALL_OUT="${TMP_DIR}/install.out"
HELP_OUT="${TMP_DIR}/install-help.out"
GETTING_STARTED="${ROOT}/docs/getting-started.md"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_documented_category() {
	local surface="$1" file="$2" category="$3"
	shift 3
	local token
	for token in "$@"; do
		grep -qF "$token" "$file" \
			|| fail "${surface} does not name ${category} category token: ${token}"
	done
}

[ -f "$INSTALL" ] || fail "installer source is absent: ${INSTALL}"
[ -f "$GETTING_STARTED" ] \
	|| fail "onboarding guide is absent: ${GETTING_STARTED}"

if ! "$INSTALL" --help >"$HELP_OUT" 2>&1; then
	cat "$HELP_OUT" >&2
	fail "installer --help failed"
fi

assert_documented_category "installer --help" "$HELP_OUT" \
	"runtime contract/schema assets" "runtime contract" "schemas"
assert_documented_category "installer --help" "$HELP_OUT" \
	"runtime-adapter guidance/templates" "runtime-adapter" "guides" "templates"
assert_documented_category "installer --help" "$HELP_OUT" \
	"VERSION identity" "VERSION" "identity"

assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"runtime contract/schema assets" "runtime contract" "schemas"
assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"runtime-adapter guidance/templates" "optional/runtime-adapters/" "guide" "template"
assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"VERSION identity" "VERSION" "identity"

mkdir -p "$TARGET"
if ! "$INSTALL" "$TARGET" --write >"$INSTALL_OUT" 2>&1; then
	cat "$INSTALL_OUT" >&2
	fail "installer --write failed"
fi

for rel in VERSION schemas/trace-schema.v1.json docs/harness-contract.yml; do
	cmp -s "${ROOT}/${rel}" "${TARGET}/${rel}" \
		|| fail "installed runtime identity/contract differs: ${rel}"
done
jq empty "${TARGET}/schemas/trace-schema.v1.json"

printf 'installed core runtime categories honored; developer execution has its own sensor\n'
)
