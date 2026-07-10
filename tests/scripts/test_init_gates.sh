#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "${OUT}"; rm -rf "${TMP_DIR}"' EXIT

cd "$ROOT"

# The real-root invocation fakes an authenticated gh (init.sh hard-fails on gh
# auth) plus terraform, to keep the test hermetic in CI and on machines without
# an active gh/az login or a terraform install. uv/az are soft in init.sh.
# Since issue #115 the repo root legitimately carries a Terraform surface
# (infra/terraform/*.tf), so init.sh must detect it — the repo is no longer
# docs-only. The docs-only path keeps coverage via a fixture repo below.
DOCSBIN="${TMP_DIR}/docsbin"
mkdir -p "$DOCSBIN"
cat > "${DOCSBIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "${DOCSBIN}/terraform" <<'SH'
#!/usr/bin/env bash
case "$1" in
	fmt|validate) exit 0 ;;
esac
exit 0
SH
chmod +x "${DOCSBIN}"/*
PATH="${DOCSBIN}:${PATH}" ./scripts/init.sh >"$OUT"

grep -q "Terraform surface detected" "$OUT" || { cat "$OUT"; exit 1; }
if grep -q "docs-only project" "$OUT"; then
	echo "init.sh must not report docs-only on a root with a Terraform surface"
	cat "$OUT"
	exit 1
fi

# --- Docs-only path (fixture repo with no language/infra surface) -------------
mkdir -p "${TMP_DIR}/docsrepo/scripts"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/docsrepo/scripts/init.sh"
cp -R "${ROOT}/profiles" "${TMP_DIR}/docsrepo/profiles"
(
	cd "${TMP_DIR}/docsrepo"
	git init -q -b main
	git config commit.gpgsign false
	printf '# docs-only fixture\n' > README.md
	PATH="${DOCSBIN}:${PATH}" ./scripts/init.sh >"$OUT"
)
grep -q "docs-only project" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "shellcheck" "$OUT" || { cat "$OUT"; exit 1; }
# markdownlint must NOT be presented as a required local gate in the docs-only flow.
if grep -q "markdownlint" "$OUT"; then
	echo "init.sh docs-only output must not recommend markdownlint as a required gate"
	cat "$OUT"
	exit 1
fi

mkdir -p "${TMP_DIR}/repo/scripts" "${TMP_DIR}/fakebin"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"
cp -R "${ROOT}/profiles" "${TMP_DIR}/repo/profiles"
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
cat > "${TMP_DIR}/fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
# Fake pnpm: every `pnpm run <script>` and `pnpm test` succeeds.
exit 0
SH
cat > "${TMP_DIR}/fakebin/node" <<'SH'
#!/usr/bin/env bash
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
printf '{"scripts":{"format":"true","lint":"true","test":"true"}}\n' > package.json
printf 'lockfileVersion: "9.0"\n' > pnpm-lock.yaml
printf '# fixture\n' > main.tf

PATH="${TMP_DIR}/fakebin:${PATH}" ./scripts/init.sh >"$OUT"

grep -q "Python surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Node surface detected (package.json, pnpm)" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Terraform surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "uv environment synced" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "node tests passing" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "terraform fmt clean" "$OUT" || { cat "$OUT"; exit 1; }

# --- Failed-gate reporting ---------------------------------------------------
# A failing quality gate must be REPORTED and turn the run into a hard failure
# (exit 1), not be swallowed. Use a Python-only repo with a fake uv whose
# `ruff format --check` gate fails while `sync` succeeds.
FAILBIN="${TMP_DIR}/failbin"
mkdir -p "${TMP_DIR}/failrepo/scripts" "$FAILBIN"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/failrepo/scripts/init.sh"
cp -R "${ROOT}/profiles" "${TMP_DIR}/failrepo/profiles"
cat > "${FAILBIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "${FAILBIN}/uv" <<'SH'
#!/usr/bin/env bash
case "$*" in
	"sync --all-groups") exit 0 ;;
	"run ruff format --check .") exit 1 ;;
	*) exit 0 ;;
esac
SH
chmod +x "${FAILBIN}"/*

cd "${TMP_DIR}/failrepo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '[project]\nname = "fixture"\nversion = "0.1.0"\n' > pyproject.toml

if PATH="${FAILBIN}:${PATH}" ./scripts/init.sh >"$OUT" 2>&1; then
	cat "$OUT"
	echo "init.sh must hard-fail when a quality gate fails"
	exit 1
fi
grep -qi "ruff format would reformat" "$OUT" || { cat "$OUT"; echo "failed gate was not reported"; exit 1; }
grep -qi "Preflight FAILED" "$OUT" || { cat "$OUT"; echo "failed gate did not surface a preflight failure"; exit 1; }

printf 'init gates smoke passed\n'