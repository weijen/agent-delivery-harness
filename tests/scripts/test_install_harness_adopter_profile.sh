#!/usr/bin/env bash
# Regression and e2e sensor (issue #312): adopter installs omit harness-dev
# sensors by default, prune clean legacy copies, and expose an explicit opt-in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

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
"$INSTALL" "$upgrade_target" --write --with-dev-sensors >"$OUT" 2>&1
[ ! -e "${upgrade_target}/.env.example" ] || {
	echo "developer install shipped project-owned environment configuration"
	exit 1
}
cmp -s "${ROOT}/.github/workflows/harness-smoke.yml" \
	"${upgrade_target}/.github/workflows/harness-smoke.yml" || {
	echo "developer install did not retain the maintainer smoke workflow"
	exit 1
}
[ -f "${upgrade_target}/tests/scripts/test_release_workflow.sh" ] || {
	echo "dev-sensor opt-in omitted an explicit harness-dev sensor"
	exit 1
}
[ -f "${upgrade_target}/tests/scripts/test_install_harness_symlinked_parent.sh" ] || {
	echo "dev-sensor opt-in omitted the symlinked-parent sensor"
	exit 1
}
[ -f "${upgrade_target}/tests/meta/test_agent_model_pins.sh" ] || {
	echo "dev-sensor opt-in omitted meta sensors"
	exit 1
}
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
[ -f "${TARGET}/scripts/github-identity-lib.sh" ] \
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
	tests/scripts/test_review_gate.sh
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

MANDATORY_FILES=(
	VERSION docs/RELEASING.md
)

MANDATORY_DIRS=(
	docs/evaluation docs/runtime-adapters tests/fixtures
	tests/evals/bin tests/evals/manifests tests/evals/fixtures tests/evals/baselines tests/evals/scorecards
)

INSTALLED_SENSORS=(
	tests/scripts/test_eval_manifest_validator.sh
	tests/scripts/test_run_evals_scorecard.sh
	tests/evals/bin/run-l0-suite.sh
)

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_verbatim() {
	local rel="$1"
	[ -f "${ROOT}/${rel}" ] \
		|| fail "mandatory source asset is absent: ${rel}"
	[ -f "${TARGET}/${rel}" ] \
		|| fail "mandatory installed runtime asset is absent: ${rel}"
	cmp -s "${ROOT}/${rel}" "${TARGET}/${rel}" \
		|| fail "installed runtime asset differs from source: ${rel}"
	case "$rel" in
	*.json)
		jq empty "${TARGET}/${rel}" >/dev/null 2>&1 \
			|| fail "installed runtime JSON asset does not parse: ${rel}"
		;;
	esac
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

run_installed_sensor() {
	local sensor="$1"
	local output
	output="${TMP_DIR}/$(basename "$sensor").out"
	if ! (cd "$TARGET" && bash "$sensor") >"$output" 2>&1; then
		printf '%s\n' "--- installed sensor failed: ${sensor} ---" >&2
		cat "$output" >&2
		fail "installed sensor failed: ${sensor}"
	fi
	printf 'PASS: installed sensor %s\n' "$sensor"
}

command -v jq >/dev/null 2>&1 \
	|| fail "jq is required to validate installed runtime JSON assets"
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
	"runtime-adapter guidance/templates" "docs/runtime-adapters/" "guides" "templates"
assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"VERSION identity" "VERSION" "identity"

mkdir -p "$TARGET"
if ! "$INSTALL" "$TARGET" --write --with-dev-sensors >"$INSTALL_OUT" 2>&1; then
	cat "$INSTALL_OUT" >&2
	fail "installer --write --with-dev-sensors failed"
fi

for rel in "${MANDATORY_FILES[@]}"; do
	assert_verbatim "$rel"
done

for directory in "${MANDATORY_DIRS[@]}"; do
	[ -d "${ROOT}/${directory}" ] \
		|| fail "mandatory source directory is absent: ${directory}"
	while IFS= read -r source_file; do
		rel="${source_file#"${ROOT}/"}"
		assert_verbatim "$rel"
	done < <(find "${ROOT}/${directory}" -type f | sort)
done

for sensor in "${INSTALLED_SENSORS[@]}"; do
	run_installed_sensor "$sensor"
done

printf 'installed harness runtime sensor passed\n'
)
