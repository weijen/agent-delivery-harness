#!/usr/bin/env bash
# test_export_optin_contract.sh — CHARACTERIZATION sensor for the opt-in trace
# export contract (issue #238, feature export-optin-contract).
#
# This feature carries a `justified` red_first_waiver: the behaviour it pins
# ALREADY EXISTS (trace-export.sh Gate 0 no-op from #144; best_effort_trace_export
# from #215). #238 only adds the local .env plumbing that turns the opt-in ON;
# it MUST NOT change this gating. This sensor freezes that contract so a future
# .env change can't silently make export mandatory or ship without the flag.
#
# Pins:
#   1. trace-export.sh with NO opt-in env → exit 0 no-op, writes NOTHING.
#   2. best_effort_trace_export returns 0 and does NOT invoke the exporter when
#      TRACE_EXPORT_OTLP or the connection string are absent.
#   3. With TRACE_EXPORT_OTLP=1 AND APPLICATIONINSIGHTS_CONNECTION_STRING set,
#      best_effort_trace_export DOES invoke ${SCRIPT_DIR}/trace-export.sh, and
#      still returns 0 even if the exporter fails (best-effort).
#
# Exit codes: 0 the opt-in contract holds · 1 a gating obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORT_SH="${ROOT}/scripts/trace-export.sh"
FINISH_LIB="${ROOT}/scripts/finish-lib.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$EXPORT_SH" ] || fail "scripts/trace-export.sh not executable"
[ -f "$FINISH_LIB" ] || fail "scripts/finish-lib.sh not found"

# --- 1. trace-export.sh no-ops (exit 0) with no opt-in env, writes nothing ----
OUT_DIR="${TMP_DIR}/out"; mkdir -p "$OUT_DIR"
set +e
(
  cd "$ROOT"
  unset TRACE_EXPORT_OTLP TRACE_EXPORT_OTLP_HTTP APPLICATIONINSIGHTS_CONNECTION_STRING
  bash "$EXPORT_SH" 999999
) >"${OUT_DIR}/stdout" 2>"${OUT_DIR}/stderr"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "trace-export.sh must exit 0 (clean no-op) when no opt-in flag is set, got ${rc}"

# --- 2 & 3. best_effort_trace_export gating -----------------------------------
# Source finish-lib.sh with stub colour helpers + a sentinel exporter.
STUB_DIR="${TMP_DIR}/scripts"; mkdir -p "$STUB_DIR"
SENTINEL="${TMP_DIR}/exporter-invoked"
cat > "${STUB_DIR}/trace-export.sh" <<EOF
#!/usr/bin/env bash
printf 'invoked %s\n' "\$1" >> "${SENTINEL}"
exit "\${STUB_EXPORTER_RC:-0}"
EOF
chmod +x "${STUB_DIR}/trace-export.sh"

# Harness that sources finish-lib.sh in isolation and calls the helper. The
# inner script always starts from a clean env (unsets the opt-in vars), then
# applies the caller's settings passed as SET_* env pairs.
run_bee() { # run_bee <KEY=VAL ...>  -> echoes "rc=<n>"
  ROOT_FL="$FINISH_LIB" STUB_DIR="$STUB_DIR" BEE_SETS="$*" \
    bash -c '
      set -uo pipefail
      unset TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING STUB_EXPORTER_RC
      for kv in $BEE_SETS; do export "${kv?}"; done
      yellow() { :; }; green() { :; }; red() { :; }
      SCRIPT_DIR="$STUB_DIR"
      ISSUE_NUM=999999
      # shellcheck disable=SC1090
      source "$ROOT_FL"
      set +e
      best_effort_trace_export
      printf "rc=%s\n" "$?"
    '
}

# 2a. No env at all → return 0, exporter NOT invoked.
rm -f "$SENTINEL"
out="$(run_bee)"
[ "$out" = "rc=0" ] || fail "best_effort_trace_export must return 0 when unconfigured, got '${out}'"
[ ! -f "$SENTINEL" ] || fail "exporter must NOT be invoked when TRACE_EXPORT_OTLP is unset"

# 2b. Flag on but connection string absent → return 0, exporter NOT invoked.
rm -f "$SENTINEL"
out="$(run_bee TRACE_EXPORT_OTLP=1)"
[ "$out" = "rc=0" ] || fail "best_effort_trace_export must return 0 when connection string absent, got '${out}'"
[ ! -f "$SENTINEL" ] || fail "exporter must NOT be invoked without APPLICATIONINSIGHTS_CONNECTION_STRING"

# 3a. Fully configured → exporter INVOKED, helper returns 0.
rm -f "$SENTINEL"
out="$(run_bee TRACE_EXPORT_OTLP=1 APPLICATIONINSIGHTS_CONNECTION_STRING=cs-fixture)"
[ "$out" = "rc=0" ] || fail "best_effort_trace_export must return 0 when configured, got '${out}'"
[ -f "$SENTINEL" ] || fail "exporter MUST be invoked when TRACE_EXPORT_OTLP=1 and connection string are both set"

# 3b. Best-effort: exporter failing must STILL return 0.
rm -f "$SENTINEL"
out="$(run_bee TRACE_EXPORT_OTLP=1 APPLICATIONINSIGHTS_CONNECTION_STRING=cs-fixture STUB_EXPORTER_RC=1)"
[ "$out" = "rc=0" ] || fail "best_effort_trace_export must swallow exporter failure and return 0, got '${out}'"
[ -f "$SENTINEL" ] || fail "exporter should have been invoked in the failing case too"

printf 'PASS: trace export stays opt-in — no-op without the flag+secret, invoked (best-effort) with both\n'
