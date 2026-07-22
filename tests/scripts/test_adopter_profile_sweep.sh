#!/usr/bin/env bash
# Regression and e2e sensor (issue #312): a clean default install contains no
# harness-development sensors and its complete installed core suite is green.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
TARGET="${TMP_DIR}/adopter"
OUT="${TMP_DIR}/sensor.out"
MANIFEST="${TARGET}/tests/harness-dev-sensors.txt"
trap 'rm -rf "$TMP_DIR"' EXIT

"$INSTALL" "$TARGET" --write >"${TMP_DIR}/install.out" 2>&1

while IFS= read -r pattern; do
	case "$pattern" in
	"" | \#*) continue ;;
	esac
	if (cd "$TARGET" && compgen -G "$pattern") | grep -q .; then
		echo "default adopter install contains harness-dev sensor pattern: $pattern"
		exit 1
	fi
done <"$MANIFEST"

(
	cd "$TARGET"
	git init -q
	git config user.email test@example.invalid
	git config user.name "Adopter Fixture"
	printf '# Adopter project\n' >README.md
	printf '# Adopter instructions\n' >AGENTS.md
	git add .
	git commit -qm "test: initialize adopter fixture"
)

failed=0
while IFS= read -r sensor; do
	rel="${sensor#"${TARGET}/"}"
	if (cd "$TARGET" && bash "$rel") >"$OUT" 2>&1; then
		printf 'PASS %s\n' "$rel"
	else
		cat "$OUT"
		printf 'FAIL %s\n' "$rel" >&2
		failed=$((failed + 1))
	fi
done < <(find "${TARGET}/tests/scripts" -type f -name 'test_*.sh' | sort)

[ "$failed" -eq 0 ] || {
	echo "$failed default adopter sensor(s) failed"
	exit 1
}

printf 'adopter profile sweep passed\n'
