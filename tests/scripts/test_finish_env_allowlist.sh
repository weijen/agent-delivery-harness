#!/usr/bin/env bash
# test_finish_env_allowlist.sh — RED sensor for the safe finish-lib .env allowlist loader
# (issue #244, feature env-allowlist-loader).
#
# Contract for load_env_allowlist <env_file>:
#   1. Reads data-only .env lines, ignoring blanks/comments and non-allowlisted keys.
#   2. Exports only the trace/OTLP allowlist, preserving process-env precedence.
#   3. Unwraps one quote layer and round-trips gen-export-env single-quote escapes.
#   4. Never evaluates values or echoes secret values.
#   5. Missing files are a clean no-op.
#
# Exit codes: 0 the loader contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINISH_LIB="${ROOT}/scripts/finish-lib.sh"
TMP_BASE="${ROOT}/.copilot-tracking/test-tmp"
mkdir -p "$TMP_BASE"
TMP_DIR="$(mktemp -d "${TMP_BASE}/finish-env-allowlist.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf 'CASE: %s\n' "$*"; }

[ -f "$FINISH_LIB" ] || fail "scripts/finish-lib.sh not found"

case_id=0
run_case() { # run_case <label> <case-body-on-stdin>
  local label="$1"
  local case_file
  case_id=$((case_id + 1))
  case_file="${TMP_DIR}/case-${case_id}.sh"
  note "$label"
  cat > "$case_file" <<'CASE_PRELUDE'
#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# finish-lib.sh resolves these only when other helpers run; define harmless
# stubs so the library can be sourced in this standalone sensor.
export SCRIPT_DIR="${ROOT}/scripts"
export ISSUE_NUM=244
red() { :; }
green() { :; }
yellow() { :; }
trace__main_root() { printf '%s\n' "$ROOT"; }

source "$FINISH_LIB"

reset_allowlist_env() {
  unset TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING TRACE_EXPORT_OTLP_HTTP \
    OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS \
    PATH_SENTINEL EVIL
}

write_env() { # write_env <name> <content>
  local name="$1"
  local content="$2"
  local path="${TMP_DIR}/${name}.env"
  printf '%s\n' "$content" > "$path"
  printf '%s\n' "$path"
}
CASE_PRELUDE
  cat >> "$case_file"
  ROOT="$ROOT" FINISH_LIB="$FINISH_LIB" TMP_DIR="$TMP_DIR" bash "$case_file"
}

run_case "allowlist-only exports allowed keys and ignores all others" <<'CASE'
reset_allowlist_env
orig_path="$PATH"
env1="$(write_env allowlist-only '# comment

TRACE_EXPORT_OTLP=1
PATH=/malicious/bin
EVIL=owned')"
load_env_allowlist "$env1"
[ "${TRACE_EXPORT_OTLP:-}" = "1" ] || fail "allowlist-only: TRACE_EXPORT_OTLP was not exported"
[ "$PATH" = "$orig_path" ] || fail "allowlist-only: PATH must not be overwritten from .env"
[ -z "${EVIL+x}" ] || fail "allowlist-only: non-allowlisted EVIL must not be exported"
CASE

run_case "quote unwrap and gen-export-env single-quote escape round-trip" <<'CASE'
reset_allowlist_env
expected_cs='InstrumentationKey=abc;IngestionEndpoint=https://x/'
expected_headers="api-key=one'two"
env2="$(write_env quote-roundtrip "APPLICATIONINSIGHTS_CONNECTION_STRING='${expected_cs}'
OTEL_EXPORTER_OTLP_HEADERS='api-key=one'\\''two'
OTEL_EXPORTER_OTLP_ENDPOINT=\"https://collector.example.invalid/v1/traces\"")"
load_env_allowlist "$env2"
[ "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" = "$expected_cs" ] \
  || fail "quote-roundtrip: connection string did not round-trip literally"
[ "${OTEL_EXPORTER_OTLP_HEADERS:-}" = "$expected_headers" ] \
  || fail "quote-roundtrip: escaped single quote did not round-trip literally"
[ "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" = "https://collector.example.invalid/v1/traces" ] \
  || fail "quote-roundtrip: double-quoted endpoint did not unwrap"
CASE

run_case "process env wins over .env values" <<'CASE'
reset_allowlist_env
export APPLICATIONINSIGHTS_CONNECTION_STRING=already
env3="$(write_env process-precedence "APPLICATIONINSIGHTS_CONNECTION_STRING='different'")"
load_env_allowlist "$env3"
[ "$APPLICATIONINSIGHTS_CONNECTION_STRING" = "already" ] \
  || fail "process-precedence: pre-set APPLICATIONINSIGHTS_CONNECTION_STRING must survive"
CASE

run_case "no command substitution or backtick execution" <<'CASE'
reset_allowlist_env
pwn1="${TMP_DIR}/pwned_244_$$_dollar"
pwn2="${TMP_DIR}/pwned_244_$$_backtick"
env4="$(write_env no-exec "APPLICATIONINSIGHTS_CONNECTION_STRING='\$(touch ${pwn1})'
OTEL_EXPORTER_OTLP_HEADERS='\`touch ${pwn2}\`'")"
load_env_allowlist "$env4"
[ ! -e "$pwn1" ] || fail "no-exec: command substitution payload executed"
[ ! -e "$pwn2" ] || fail "no-exec: backtick payload executed"
[ "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}" = "\$(touch ${pwn1})" ] \
  || fail "no-exec: dollar payload should be carried literally"
[ "${OTEL_EXPORTER_OTLP_HEADERS:-}" = "\`touch ${pwn2}\`" ] \
  || fail "no-exec: backtick payload should be carried literally"
CASE

run_case "secret values are not echoed" <<'CASE'
reset_allowlist_env
secret='secret-value-244-do-not-print'
env5="$(write_env secret-output "APPLICATIONINSIGHTS_CONNECTION_STRING='${secret}'")"
out_file="${TMP_DIR}/loader.stdout"
err_file="${TMP_DIR}/loader.stderr"
load_env_allowlist "$env5" >"$out_file" 2>"$err_file"
if grep -qF "$secret" "$out_file" "$err_file"; then
  fail "secret-output: loader must not print secret values"
fi
CASE

run_case "absent file is a clean no-op" <<'CASE'
reset_allowlist_env
missing_file="${TMP_DIR}/does-not-exist.env"
load_env_allowlist "$missing_file"
[ -z "${TRACE_EXPORT_OTLP+x}" ] || fail "absent-file: TRACE_EXPORT_OTLP must remain unset"
[ -z "${APPLICATIONINSIGHTS_CONNECTION_STRING+x}" ] \
  || fail "absent-file: APPLICATIONINSIGHTS_CONNECTION_STRING must remain unset"
CASE

printf 'PASS: finish-lib load_env_allowlist safely loads only allowlisted .env keys without eval or secret echo\n'
