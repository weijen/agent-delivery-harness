#!/usr/bin/env bash
# test_env_example_export_vars.sh — regression sensor for the shared
# .env.example App Insights / OTLP export placeholders (issue #238,
# feature env-example-export-vars).
#
# #238 keeps ONE shared local-config file. This sensor pins that the committed
# .env.example gained non-secret placeholders for the trace-export env
# contract, alongside the #227 COPILOT_OTEL_* keys, and that it carries NO real
# secret (connection string / instrumentation key / ingestion endpoint).
#
# Exit codes: 0 the template contract holds · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_EXAMPLE="${ROOT}/.env.example"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$ENV_EXAMPLE" ] || fail ".env.example not found (${ENV_EXAMPLE})"

# It must stay tracked (the template is committed; only .env is ignored).
if command -v git >/dev/null 2>&1; then
  ( cd "$ROOT" && git ls-files --error-unmatch .env.example >/dev/null 2>&1 ) \
    || fail ".env.example must be a tracked file"
fi

# 1. Required export placeholders present (as `KEY=` assignments).
for key in TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING \
           TRACE_EXPORT_OTLP_HTTP OTEL_EXPORTER_OTLP_ENDPOINT \
           OTEL_EXPORTER_OTLP_HEADERS; do
  grep -qE "^${key}=" "$ENV_EXAMPLE" \
    || fail ".env.example must define a '${key}=' placeholder (trace-export env contract)"
done

# 2. The #227 keys must survive (one shared file, not a second env path).
for key in COPILOT_OTEL_ENABLED COPILOT_OTEL_FILE_EXPORTER_PATH; do
  grep -qE "^${key}=" "$ENV_EXAMPLE" \
    || fail ".env.example must still carry the #227 '${key}=' placeholder (shared file)"
done

# 3. Every assignment must be an EMPTY placeholder — no baked-in value that
#    could be (or look like) a secret. A non-empty RHS on a secret-bearing key
#    is a leak.
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  key="${line%%=*}"
  val="${line#*=}"
  if [ -n "$val" ]; then
    fail ".env.example assignment must be an empty placeholder, got a value on: ${key}"
  fi
done < "$ENV_EXAMPLE"

# 4. Byte-level secret-shape scan (belt and suspenders): the template must not
#    contain an App Insights connection-string secret shape anywhere.
if grep -qiE 'InstrumentationKey=[0-9a-fA-F-]{8,}|IngestionEndpoint=https?://[^[:space:]]+' "$ENV_EXAMPLE"; then
  fail ".env.example must not contain a real InstrumentationKey/IngestionEndpoint secret shape"
fi

printf 'PASS: .env.example carries empty, non-secret export + OTel placeholders in one shared file\n'
