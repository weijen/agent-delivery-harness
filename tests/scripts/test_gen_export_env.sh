#!/usr/bin/env bash
# test_gen_export_env.sh — regression sensor for scripts/gen-export-env.sh
# (issue #238, feature gen-export-env-script).
#
# The generator writes/updates a local, gitignored .env with the App Insights
# connection string sourced from `terraform output -raw connection_string`,
# WITHOUT ever printing the secret. Contract:
#   1. Seeds .env from .env.example when absent, then sets TRACE_EXPORT_OTLP=1
#      and APPLICATIONINSIGHTS_CONNECTION_STRING from terraform output.
#   2. The sourced .env yields the exact connection string (proves the value is
#      quoted so its `;`/`=`/`/` characters survive `set -a; source .env`).
#   3. The connection string is NEVER echoed to stdout/stderr.
#   4. Pre-existing keys (e.g. COPILOT_OTEL_ENABLED) are preserved; keys are
#      upserted idempotently (no duplicate assignment after two runs).
#   5. .env is gitignored in the real repo.
#   6. A missing/empty terraform output fails without writing a secret.
#
# Uses a FAKE terraform on PATH and a SYNTHETIC connection string.
#
# Exit codes: 0 the generator contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${ROOT}/scripts/gen-export-env.sh"
ENV_EXAMPLE_SRC="${ROOT}/.env.example"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$GEN" ] || fail "scripts/gen-export-env.sh not found (${GEN}) — feature gen-export-env-script not implemented"
[ -x "$GEN" ] || fail "scripts/gen-export-env.sh must be executable"
[ -f "$ENV_EXAMPLE_SRC" ] || fail ".env.example not found"

# SYNTHETIC connection string (fixture-only; carries ; = / . like a real one).
SYNTH_CS='InstrumentationKey=00000000-1111-2222-3333-444444444444;IngestionEndpoint=https://example.invalid/;LiveEndpoint=https://live.example.invalid/'

# Fake terraform on PATH: prints the synthetic CS for `output -raw connection_string`.
FAKEBIN="${TMP_DIR}/bin"
mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/terraform" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "output" ] && printf '%s ' "\$@" | grep -q 'connection_string'; then
  printf '%s' '${SYNTH_CS}'
  exit 0
fi
exit 0
EOF
chmod +x "${FAKEBIN}/terraform"

TF_DIR="${TMP_DIR}/tf"; mkdir -p "$TF_DIR"
ENV_EXAMPLE_COPY="${TMP_DIR}/.env.example"; cp "$ENV_EXAMPLE_SRC" "$ENV_EXAMPLE_COPY"

run_gen() { # run_gen <env_file>  -> stdout+stderr captured to $RUN_OUT
  RUN_OUT="${TMP_DIR}/run.log"
  PATH="${FAKEBIN}:${PATH}" ENV_FILE="$1" TF_DIR="$TF_DIR" ENV_EXAMPLE="$ENV_EXAMPLE_COPY" \
    bash "$GEN" > "$RUN_OUT" 2>&1
}

# --- Case 1: seed from .env.example when .env absent --------------------------
ENV1="${TMP_DIR}/env1"
run_gen "$ENV1" || fail "case1: generator exited non-zero: $(cat "$RUN_OUT")"
[ -f "$ENV1" ] || fail "case1: .env not created"
# Secret must NOT appear in output.
grep -qF "$SYNTH_CS" "$RUN_OUT" && fail "case1: connection string was ECHOED to output (must never print the secret)"
# Sourcing must reproduce the exact value (quoting survives ; = /).
( set -a; # shellcheck disable=SC1090
  . "$ENV1"; set +a
  [ "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" = "$SYNTH_CS" ] \
    || { printf 'got: %s\n' "${APPLICATIONINSIGHTS_CONNECTION_STRING:-<unset>}" >&2; exit 3; }
  [ "${TRACE_EXPORT_OTLP:-}" = "1" ] || exit 4
) || fail "case1: sourced .env must yield the exact connection string and TRACE_EXPORT_OTLP=1 (quoting must survive)"
# Seeded from example: an #227 placeholder key is present.
grep -qE '^COPILOT_OTEL_ENABLED=' "$ENV1" || fail "case1: .env should be seeded from .env.example (COPILOT_OTEL_ENABLED placeholder missing)"

# --- Case 2: preserve pre-existing keys + idempotent upsert -------------------
ENV2="${TMP_DIR}/env2"
{
  printf 'COPILOT_OTEL_ENABLED=1\n'
  printf 'TRACE_EXPORT_OTLP=\n'
  printf 'SOME_OTHER_KEY=keepme\n'
} > "$ENV2"
run_gen "$ENV2" || fail "case2: generator exited non-zero: $(cat "$RUN_OUT")"
run_gen "$ENV2" || fail "case2b: second run exited non-zero: $(cat "$RUN_OUT")"
grep -qE '^COPILOT_OTEL_ENABLED=1$' "$ENV2" || fail "case2: pre-existing COPILOT_OTEL_ENABLED=1 must be preserved"
grep -qE '^SOME_OTHER_KEY=keepme$' "$ENV2" || fail "case2: unrelated key must be preserved"
cs_lines="$(grep -cE '^APPLICATIONINSIGHTS_CONNECTION_STRING=' "$ENV2" 2>/dev/null || true)"
[ "$cs_lines" = "1" ] || fail "case2: exactly one APPLICATIONINSIGHTS_CONNECTION_STRING assignment expected (idempotent), got ${cs_lines}"
otlp_lines="$(grep -cE '^TRACE_EXPORT_OTLP=' "$ENV2" 2>/dev/null || true)"
[ "$otlp_lines" = "1" ] || fail "case2: exactly one TRACE_EXPORT_OTLP assignment expected, got ${otlp_lines}"

# --- Case 3: .env is gitignored in the real repo -----------------------------
if command -v git >/dev/null 2>&1; then
  ( cd "$ROOT" && git check-ignore -q .env ) \
    || fail "case3: .env must be gitignored in the repo"
fi

# --- Case 4: missing terraform output fails without writing a secret ----------
ENV4="${TMP_DIR}/env4"
EMPTYBIN="${TMP_DIR}/emptybin"; mkdir -p "$EMPTYBIN"
cat > "${EMPTYBIN}/terraform" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${EMPTYBIN}/terraform"
set +e
PATH="${EMPTYBIN}:${PATH}" ENV_FILE="$ENV4" TF_DIR="$TF_DIR" ENV_EXAMPLE="$ENV_EXAMPLE_COPY" \
  bash "$GEN" > "${TMP_DIR}/run4.log" 2>&1
rc4=$?
set -e
[ "$rc4" -ne 0 ] || fail "case4: generator must FAIL when terraform yields no connection string"
if [ -f "$ENV4" ]; then
  grep -qE '^APPLICATIONINSIGHTS_CONNECTION_STRING=.+' "$ENV4" \
    && fail "case4: no connection string must be written when terraform output is empty"
fi

printf 'PASS: gen-export-env.sh upserts a quoted, gitignored .env from terraform output without echoing the secret\n'
