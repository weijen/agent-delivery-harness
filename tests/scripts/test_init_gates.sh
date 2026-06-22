#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "${OUT}"; rm -rf "${TMP_DIR}"' EXIT

cd "$ROOT"
./scripts/init.sh >"$OUT"

grep -q "docs-only project" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "shellcheck" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "markdownlint" "$OUT" || { cat "$OUT"; exit 1; }

mkdir -p "${TMP_DIR}/repo/scripts" "${TMP_DIR}/fakebin"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"
cat > "${TMP_DIR}/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "${TMP_DIR}/fakebin/az" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "account" ] && [ "$2" = "show" ]; then
	if [ "${AZURE_CONFIG_DIR:-}" ]; then :; fi
	printf 'fixture-sub\n'
	exit 0
fi
SH
cat > "${TMP_DIR}/fakebin/uv" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
	"sync --all-groups") exit 0 ;;
	"run ruff") exit 0 ;;
	"run mypy") exit 0 ;;
	"run pytest") exit 0 ;;
esac
exit 0
SH
cat > "${TMP_DIR}/fakebin/go" <<'SH'
#!/usr/bin/env bash
case "$1" in
	test|vet) exit 0 ;;
esac
exit 0
SH
cat > "${TMP_DIR}/fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
[ "$1" = "test" ] && exit 0
exit 0
SH
cat > "${TMP_DIR}/fakebin/terraform" <<'SH'
#!/usr/bin/env bash
case "$1" in
	fmt|validate) exit 0 ;;
esac
exit 0
SH
chmod +x "${TMP_DIR}/fakebin"/*

cd "${TMP_DIR}/repo"
git init -q -b main
git config commit.gpgsign false
printf '[project]\nname = "fixture"\nversion = "0.1.0"\n' > pyproject.toml
printf 'module fixture\n' > go.mod
printf '{"scripts":{"test":"true"}}\n' > package.json
printf '# fixture\n' > main.tf

PATH="${TMP_DIR}/fakebin:${PATH}" ./scripts/init.sh >"$OUT"

grep -q "Python surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Go surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Node/pnpm surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Terraform surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "uv environment synced" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "go test passing" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "pnpm test passing" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "terraform fmt clean" "$OUT" || { cat "$OUT"; exit 1; }

printf 'init gates smoke passed\n'