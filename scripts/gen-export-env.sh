#!/usr/bin/env bash
# gen-export-env.sh — generate/update a local, gitignored .env with the App
# Insights connection string for trace export (issue #238).
#
# The connection string is read from `terraform output -raw connection_string`
# (the Terraform output is sensitive=true) and written to .env WITHOUT ever
# being echoed to the terminal. This is the ONLY supported way to put the real
# secret on disk locally — the committed .env.example never carries it.
#
# The value is single-quoted in .env so its `;`, `=` and `/` characters survive
# `set -a; source .env; set +a`.
#
# Overridable via env for testing: ENV_FILE, ENV_EXAMPLE, TF_DIR.
#
# Usage:
#   ./scripts/gen-export-env.sh
#   set -a; source .env; set +a     # then export honours the settings

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
ENV_EXAMPLE="${ENV_EXAMPLE:-${REPO_ROOT}/.env.example}"
TF_DIR="${TF_DIR:-${REPO_ROOT}/infra/terraform}"

log() { printf '%s\n' "$*" >&2; }

# 1. Seed .env from the template when absent (keeps every placeholder + docs).
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$ENV_EXAMPLE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  else
    : > "$ENV_FILE"
  fi
fi

# 2. Read the connection string from terraform WITHOUT printing it.
if ! command -v terraform >/dev/null 2>&1; then
  log "error: terraform not found on PATH; cannot read connection_string. .env not updated."
  exit 1
fi

connection_string="$( { cd "$TF_DIR" && terraform output -raw connection_string 2>/dev/null; } || true )"
if [ -z "$connection_string" ]; then
  log "error: 'terraform output -raw connection_string' returned nothing (cd ${TF_DIR}). .env not updated."
  log "       Run 'terraform apply' first, or set APPLICATIONINSIGHTS_CONNECTION_STRING in .env by hand."
  exit 1
fi

# 3. Upsert keys in place without echoing the secret. Values are single-quoted
#    (with embedded single quotes escaped) so sourcing is byte-exact.
sq_escape() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

upsert() { # upsert <key> <value>
  local key="$1" value="$2" tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  grep -vE "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf "%s='%s'\n" "$key" "$(sq_escape "$value")" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

upsert TRACE_EXPORT_OTLP "1"
upsert LOG_EXPORT_OTLP "1"
upsert APPLICATIONINSIGHTS_CONNECTION_STRING "$connection_string"

chmod 600 "$ENV_FILE" 2>/dev/null || true

log "✓ Wrote export settings to ${ENV_FILE} (connection string not echoed)."
log "  Load them with: set -a; source .env; set +a"
