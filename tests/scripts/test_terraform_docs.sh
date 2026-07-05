#!/usr/bin/env bash
# Regression sensor (issue #115, feature tf-fmt-gate-docs): the module README
# must document what is deliberately NOT committed — the azurerm remote-state
# backend (configured per-deployment via -backend-config), the az-login/init/
# plan/apply workflow, env-sourced consumption of the connection string by the
# OTLP exporter (#112, output → env var, never committed), and the security
# boundary pointer (dataset governance / security evals). Plus an honest,
# conditional `terraform fmt -check` leg: runs when terraform is on PATH,
# SKIPs with a note otherwise (test_go_profile.sh optional-tool precedent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

TF_DIR="infra/terraform"
readme="$TF_DIR/README.md"

# --- 1. README sections ---------------------------------------------------------
if [ ! -f "$readme" ]; then
	note "missing $readme — remote-state/workflow/consumption story undocumented"
else
	# Remote state: azurerm backend expectation, wired per-deployment, never committed.
	if ! grep -Eiq 'backend[^.]{0,40}azurerm|azurerm[^.]{0,40}backend' "$readme"; then
		note "$readme: remote-state expectation (azurerm backend) not documented"
	fi
	if ! grep -q -- '-backend-config' "$readme"; then
		note "$readme: -backend-config per-deployment wiring not documented"
	fi
	if ! grep -Eiq 'ne(ver|ither)[^.]*commit|not[[:space:]]+commit' "$readme"; then
		note "$readme: must state backend/secrets are never committed"
	fi
	# Apply workflow: az login + init + plan/apply.
	if ! grep -Eq 'az login' "$readme"; then
		note "$readme: workflow must cover az login auth"
	fi
	if ! grep -Eq 'terraform init' "$readme"; then
		note "$readme: workflow must cover terraform init"
	fi
	if ! grep -Eq 'terraform plan' "$readme"; then
		note "$readme: workflow must cover terraform plan"
	fi
	if ! grep -Eq 'terraform apply' "$readme"; then
		note "$readme: workflow must cover terraform apply"
	fi
	# Env-sourced consumption by #112: output -raw → env var, never committed.
	if ! grep -Eq 'terraform output -raw[[:space:]]+connection_string' "$readme"; then
		note "$readme: #112 consumption via 'terraform output -raw connection_string' not documented"
	fi
	if ! grep -q 'APPLICATIONINSIGHTS_CONNECTION_STRING' "$readme"; then
		note "$readme: APPLICATIONINSIGHTS_CONNECTION_STRING env consumption not documented"
	fi
	# Security boundary pointer.
	if ! grep -Eq 'dataset-governance|security-evals' "$readme"; then
		note "$readme: security boundary pointer (dataset-governance / security-evals) missing"
	fi
fi

# --- 2. Conditional fmt gate (honest skip when the tool is absent) ---------------
if command -v terraform >/dev/null 2>&1; then
	if [ -d "$TF_DIR" ]; then
		if ! terraform fmt -check -recursive "$TF_DIR" >/dev/null; then
			note "terraform fmt drift under $TF_DIR — run: terraform fmt -recursive $TF_DIR"
		fi
	else
		note "missing $TF_DIR/ — nothing to fmt-check"
	fi
else
	echo "SKIP: terraform not installed — fmt gate not exercised"
fi

if [ "$fail" -ne 0 ]; then
	echo "terraform fmt-gate/docs sensor FAILED"
	exit 1
fi
echo "terraform fmt-gate/docs checks passed"
