#!/usr/bin/env bash
# Regression sensor (issue #115, feature tf-pinned-skeleton): the telemetry-sink
# stack skeleton under infra/terraform/ must exist with pinned versions
# (required_version ">= 1.9", hashicorp/azurerm with a pessimistic ~> 4.x pin),
# a credential-free provider block with features {}, typed+described variables
# for retention_in_days / daily_cap_gb / sampling_percentage (conductor-resolved:
# ONE daily-cap knob wired to both workspace daily_quota_gb and App Insights
# daily_data_cap_in_gb), NO committed backend block (remote state is documented,
# not configured), and a secrets-free terraform.tfvars.example.
# Static grep-based sensor — no terraform binary required (CI has none).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

TF_DIR="infra/terraform"

if [ ! -d "$TF_DIR" ]; then
	echo "✗ missing $TF_DIR/ — telemetry-sink stack skeleton not created"
	echo "terraform pinned-skeleton sensor FAILED"
	exit 1
fi

# --- 1. Skeleton files exist ---------------------------------------------------
for f in versions.tf providers.tf variables.tf terraform.tfvars.example; do
	if [ ! -f "$TF_DIR/$f" ]; then
		note "missing $TF_DIR/$f"
	fi
done

# --- 2. versions.tf: pinned core + provider -----------------------------------
versions="$TF_DIR/versions.tf"
if [ -f "$versions" ]; then
	if ! grep -Eq 'required_version[[:space:]]*=[[:space:]]*">=[[:space:]]*1\.9"' "$versions"; then
		note "$versions: required_version constraint '>= 1.9' not pinned"
	fi
	if ! grep -Eq 'source[[:space:]]*=[[:space:]]*"hashicorp/azurerm"' "$versions"; then
		note "$versions: azurerm provider source hashicorp/azurerm not declared"
	fi
	if ! grep -Eq 'version[[:space:]]*=[[:space:]]*"~>[[:space:]]*4(\.[0-9]+)?"' "$versions"; then
		note "$versions: azurerm not pinned with a pessimistic '~> 4.x' constraint"
	fi
fi

# --- 3. providers.tf: features {} and NO credential arguments -------------------
providers="$TF_DIR/providers.tf"
if [ -f "$providers" ]; then
	if ! grep -Eq 'features[[:space:]]*\{' "$providers"; then
		note "$providers: azurerm 'features {}' block missing"
	fi
	# Credentials never live in provider blocks (env ARM_* / az login only).
	cred_hits="$(grep -En '(client_secret|client_id|client_certificate|subscription_id|tenant_id)[[:space:]]*=' "$providers" || true)"
	if [ -n "$cred_hits" ]; then
		note "$providers: credential-looking provider argument(s): $cred_hits"
	fi
fi

# --- 4. variables.tf: typed + described knobs, pinned defaults ------------------
# Pinned per plan: retention_in_days default 30, sampling_percentage default 100,
# daily_cap_gb must carry an explicit default (single cap knob for both resources).
variables="$TF_DIR/variables.tf"
var_block() {
	# Print the body of variable "<name>" { ... } (brace-depth aware).
	awk -v name="$1" '
		$0 ~ "^variable[[:space:]]+\"" name "\"" { inblock = 1 }
		inblock {
			print
			o = gsub(/\{/, "{")
			c = gsub(/\}/, "}")
			if (o > 0) opened = 1
			depth += o - c
			if (opened && depth <= 0) exit
		}
	' "$variables"
}
if [ -f "$variables" ]; then
	for v in retention_in_days daily_cap_gb sampling_percentage; do
		block="$(var_block "$v")"
		if [ -z "$block" ]; then
			note "$variables: variable \"$v\" not declared"
			continue
		fi
		if ! printf '%s\n' "$block" | grep -Eq '^[[:space:]]*type[[:space:]]*='; then
			note "$variables: variable \"$v\" has no type"
		fi
		if ! printf '%s\n' "$block" | grep -Eq '^[[:space:]]*description[[:space:]]*='; then
			note "$variables: variable \"$v\" has no description"
		fi
		if ! printf '%s\n' "$block" | grep -Eq '^[[:space:]]*default[[:space:]]*='; then
			note "$variables: variable \"$v\" has no explicit default"
		fi
	done
	if [ -n "$(var_block retention_in_days)" ] &&
		! var_block retention_in_days | grep -Eq 'default[[:space:]]*=[[:space:]]*30\b'; then
		note "$variables: retention_in_days default must be 30 (plan pin)"
	fi
	if [ -n "$(var_block sampling_percentage)" ] &&
		! var_block sampling_percentage | grep -Eq 'default[[:space:]]*=[[:space:]]*100\b'; then
		note "$variables: sampling_percentage default must be 100 (plan pin)"
	fi

	# Loop-2 nit 4: every telemetry knob fails fast at plan time via a
	# validation block. Bounds pinned: retention 30-730 (LAW limits),
	# sampling 0-100, daily_cap_gb strictly > 0 — the workspace's -1
	# "unlimited" sentinel is rejected by App Insights daily_data_cap_in_gb,
	# so a shared knob must ban it.
	for v in retention_in_days daily_cap_gb sampling_percentage; do
		block="$(var_block "$v")"
		if [ -z "$block" ]; then
			continue # absence already reported above
		fi
		if ! printf '%s\n' "$block" | grep -Eq '^[[:space:]]*validation[[:space:]]*\{'; then
			note "$variables: variable \"$v\" has no validation block (fail fast at plan time)"
			continue
		fi
		# Bounds are asserted against the condition expression ONLY — the
		# error_message prose echoes the numbers and would mask drift.
		cond="$(printf '%s\n' "$block" | grep -E '^[[:space:]]*condition[[:space:]]*=' || true)"
		case "$v" in
		retention_in_days)
			if ! printf '%s\n' "$cond" | grep -Eq '\b30\b'; then
				note "$variables: retention_in_days validation condition must enforce the 30 lower bound"
			fi
			if ! printf '%s\n' "$cond" | grep -Eq '\b730\b'; then
				note "$variables: retention_in_days validation condition must enforce the 730 upper bound"
			fi
			;;
		sampling_percentage)
			if ! printf '%s\n' "$cond" | grep -Eq '\b0\b'; then
				note "$variables: sampling_percentage validation condition must enforce the 0 lower bound"
			fi
			if ! printf '%s\n' "$cond" | grep -Eq '\b100\b'; then
				note "$variables: sampling_percentage validation condition must enforce the 100 upper bound"
			fi
			;;
		daily_cap_gb)
			if ! printf '%s\n' "$cond" | grep -Eq '>[[:space:]]*0\b'; then
				note "$variables: daily_cap_gb validation condition must require > 0 (ban the -1 unlimited sentinel)"
			fi
			;;
		esac
	done
fi

# --- 5. No backend block committed anywhere in the stack ------------------------
# Remote state (backend "azurerm" + locking) is documented in the README, never
# configured in committed HCL. Only .tf files can carry a backend block.
backend_hits="$(grep -rEn 'backend[[:space:]]+"' "$TF_DIR" --include='*.tf' || true)"
if [ -n "$backend_hits" ]; then
	note "committed backend block found (remote state must stay documented-only): $backend_hits"
fi

# --- 6. tfvars.example: key = value shape, synthetic placeholders only ----------
example="$TF_DIR/terraform.tfvars.example"
if [ -f "$example" ]; then
	bad_lines="$(grep -Evn '^[[:space:]]*(#|$)|^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=' "$example" || true)"
	if [ -n "$bad_lines" ]; then
		note "$example: non key=value line(s): $bad_lines"
	fi
	# Comments are exempt; the guard targets secret-shaped keys/values.
	secret_kw="$(grep -n '' "$example" | grep -Ev '^[0-9]+:[[:space:]]*#' |
		grep -Ei '(secret|password|token|connection_string|instrumentationkey)' || true)"
	if [ -n "$secret_kw" ]; then
		note "$example: secret-looking content (placeholders must be non-secret knobs): $secret_kw"
	fi
	# Real-looking GUIDs (subscription/tenant ids) are forbidden; the all-zero
	# GUID is the only acceptable synthetic placeholder shape.
	guids="$(grep -Eion '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$example" |
		grep -iv '00000000-0000-0000-0000-000000000000' || true)"
	if [ -n "$guids" ]; then
		note "$example: real-looking GUID(s) — use the all-zero placeholder or drop the field: $guids"
	fi
fi

if [ "$fail" -ne 0 ]; then
	echo "terraform pinned-skeleton sensor FAILED"
	exit 1
fi
echo "terraform pinned-skeleton checks passed"
