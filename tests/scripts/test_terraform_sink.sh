#!/usr/bin/env bash
# Regression sensor (issue #115, feature tf-sink-resources): main.tf must
# declare EXACTLY one in-stack resource group (conductor fork), one Log
# Analytics workspace, and one workspace-based Application Insights component;
# the single daily-cap knob (var.daily_cap_gb) must be wired to BOTH the
# workspace daily_quota_gb and App Insights daily_data_cap_in_gb (conductor
# fork); retention/sampling wired to their vars; outputs.tf marks
# connection_string AND instrumentation_key sensitive = true; and no
# dashboard/alert/monitor footprint exists anywhere (issue non-goal).
# Static grep/awk sensor — no terraform binary required (CI has none).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

TF_DIR="infra/terraform"
main="$TF_DIR/main.tf"
outputs="$TF_DIR/outputs.tf"

missing=0
for f in "$main" "$outputs"; do
	if [ ! -f "$f" ]; then
		note "missing $f — telemetry-sink resources not authored"
		missing=1
	fi
done
if [ "$missing" -ne 0 ]; then
	echo "terraform sink-resources sensor FAILED"
	exit 1
fi

# Print the body of the first block whose opening line matches the header
# regex (brace-depth aware, handles one-line blocks).
hcl_block() {
	awk -v hdr="$2" '
		$0 ~ hdr { inblock = 1 }
		inblock {
			print
			o = gsub(/\{/, "{")
			c = gsub(/\}/, "}")
			if (o > 0) opened = 1
			depth += o - c
			if (opened && depth <= 0) exit
		}
	' "$1"
}

# --- 1. Exactly one of each sink resource, in-stack RG included ----------------
count_res() { grep -Ec "^resource[[:space:]]+\"$1\"" "$main" || true; }
for r in azurerm_resource_group azurerm_log_analytics_workspace azurerm_application_insights; do
	n="$(count_res "$r")"
	if [ "$n" -ne 1 ]; then
		note "$main: expected exactly one resource \"$r\", found $n"
	fi
done

# --- 2. Workspace wiring: retention + single cap knob --------------------------
law="$(hcl_block "$main" '^resource[[:space:]]+"azurerm_log_analytics_workspace"')"
if [ -n "$law" ]; then
	if ! printf '%s\n' "$law" | grep -Eq 'retention_in_days[[:space:]]*=[[:space:]]*var\.retention_in_days\b'; then
		note "$main: workspace retention_in_days not wired to var.retention_in_days"
	fi
	if ! printf '%s\n' "$law" | grep -Eq 'daily_quota_gb[[:space:]]*=[[:space:]]*var\.daily_cap_gb\b'; then
		note "$main: workspace daily_quota_gb not wired to var.daily_cap_gb (single cap knob)"
	fi
fi

# --- 3. App Insights: workspace-based, sampled, same cap knob ------------------
appi="$(hcl_block "$main" '^resource[[:space:]]+"azurerm_application_insights"')"
if [ -n "$appi" ]; then
	if ! printf '%s\n' "$appi" | grep -Eq 'workspace_id[[:space:]]*=[[:space:]]*azurerm_log_analytics_workspace\.'; then
		note "$main: application_insights workspace_id must reference the in-stack workspace (workspace-based, not classic)"
	fi
	if ! printf '%s\n' "$appi" | grep -Eq 'application_type[[:space:]]*='; then
		note "$main: application_insights has no application_type"
	fi
	if ! printf '%s\n' "$appi" | grep -Eq 'sampling_percentage[[:space:]]*=[[:space:]]*var\.sampling_percentage\b'; then
		note "$main: application_insights sampling_percentage not wired to var.sampling_percentage"
	fi
	if ! printf '%s\n' "$appi" | grep -Eq 'daily_data_cap_in_gb[[:space:]]*=[[:space:]]*var\.daily_cap_gb\b'; then
		note "$main: application_insights daily_data_cap_in_gb not wired to var.daily_cap_gb (single cap knob)"
	fi
fi

# --- 4. Sensitive outputs -------------------------------------------------------
for o in connection_string instrumentation_key; do
	block="$(hcl_block "$outputs" "^output[[:space:]]+\"$o\"")"
	if [ -z "$block" ]; then
		note "$outputs: output \"$o\" not declared"
	elif ! printf '%s\n' "$block" | grep -Eq 'sensitive[[:space:]]*=[[:space:]]*true\b'; then
		note "$outputs: output \"$o\" must set sensitive = true"
	fi
done

# --- 5. Non-goal guard: no alerts / monitor / portal-dashboard footprint ------
# Issue #113 deliberately adds ONE azurerm_application_insights_workbook (the
# harness-quality dashboard), so the workbook is no longer a non-goal. Alerts,
# action groups, monitor.* and portal/legacy dashboards stay out of scope
# (#113 documents suggested alerts as spec only — not deployed resources).
nongoal="$(grep -rEn '^resource[[:space:]]+"(azurerm_monitor_[a-z0-9_]+|azurerm_portal_dashboard|azurerm_dashboard[a-z0-9_]*|[a-z0-9_]*action_group[a-z0-9_]*)"' "$TF_DIR" --include='*.tf' || true)"
if [ -n "$nongoal" ]; then
	note "alert/monitor/portal-dashboard resource present (out of scope): $nongoal"
fi

if [ "$fail" -ne 0 ]; then
	echo "terraform sink-resources sensor FAILED"
	exit 1
fi
echo "terraform sink-resources checks passed"
