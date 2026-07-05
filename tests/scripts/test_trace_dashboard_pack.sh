#!/usr/bin/env bash
# test_trace_dashboard_pack.sh — RED regression sensor (issue #113, feature
# harness-quality-workbook). This sensor IS the executable spec for the
# live-deployed Azure Workbook dashboard pack. It stays RED until the
# implementer authors BOTH artifacts:
#
#   1. a Terraform file under infra/terraform/ declaring an
#      `azurerm_application_insights_workbook` resource whose `serialized_data`
#      is an embedded Workbook JSON document (dashboard panels), AND
#   2. docs/evaluation/dashboards/README.md documenting the pack.
#
# THE CONTRACT (what the implementer must satisfy — every leg an obligation):
#
#   A. EXISTENCE. The workbook .tf and docs/evaluation/dashboards/README.md
#      both exist; the .tf declares exactly one azurerm_application_insights_workbook.
#
#   B. ALLOWLIST FIDELITY (charting-a-dropped-key guard). Every property /
#      customDimensions[...] key referenced by the workbook's embedded KQL
#      MUST be shippable per the REAL exporter allowlist — parsed LIVE from the
#      `def allowlist:` block in scripts/trace-export.sh (never a hardcoded
#      copy) — OR carry the gen_ai.usage. prefix OR be a `measurements` field.
#      Charting a key the exporter drops means charting perpetual nulls.
#
#   C. TABLE CORRECTNESS. The exporter maps tool+lifecycle spans →
#      `dependencies` (RemoteDependencyData) and agent+model spans →
#      `customEvents` (EventData). So: a KQL query over `dependencies` may only
#      reference tool/lifecycle-shaped keys; a query over `customEvents` may
#      only reference agent/model-shaped keys. A dimension charted against the
#      wrong table returns empty forever.
#
#   D. EXPLICIT-TIMESPAN LINT (source-span-timestamp gotcha). Each embedded
#      KQL query MUST set an explicit time bound (a workbook TimeRange
#      parameter binding, an explicit `where timestamp/TimeGenerated >= ...`,
#      or an `| where ... ago(...)` bound). Relying on the portal default lets
#      a query silently scan/omit the wrong window.
#
#   E. HONEST METRICS. The pack + README must (i) name the contract-deferred
#      metrics (review-blocking findings, per-feature attribution) as
#      explicitly UNAVAILABLE / deferred, and (ii) NEVER relabel
#      red_reentry_free_rate as "first-pass green" (grep-assert both).
#
#   F. NO COMMITTED SECRET. The workbook must reference the module's OWN App
#      Insights resource by Terraform reference
#      (azurerm_application_insights.telemetry...) and MUST NOT embed any
#      connection-string literal, InstrumentationKey, or hardcoded foreign
#      Azure resource id / GUID literal.
#
#   G. TERRAFORM FMT. infra/terraform is `terraform fmt -check` clean (validate
#      is best-effort, only when a .terraform/ init dir is present).
#
# Static sensor: jq (workbook JSON) + awk/grep (HCL wrapper + allowlist parse).
# terraform is optional (honest SKIP when absent). No `A && B || C` chains.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }
ok() { echo "· $*"; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required (workbook JSON is jq-parsed)"; exit 2; }

TF_DIR="infra/terraform"
EXPORT_SH="scripts/trace-export.sh"
DASH_README="docs/evaluation/dashboards/README.md"

# =============================================================================
# Parse the REAL allowlist live from trace-export.sh (never hardcode a copy).
# The `def allowlist:` block is a jq list literal; slurp from the "def
# allowlist:" line to its terminating "];" and evaluate it as a JSON array.
# =============================================================================
ALLOWLIST_JSON=""
if [ ! -f "$EXPORT_SH" ]; then
	note "missing $EXPORT_SH — cannot parse the shippable-attribute allowlist (sensor cannot verify key fidelity)"
else
	allowlist_src="$(awk '
		/^def[[:space:]]+allowlist:/ { grab = 1 }
		grab {
			line = $0
			sub(/^def[[:space:]]+allowlist:[[:space:]]*/, "", line)
			body = body " " line
			if ($0 ~ /\];/) { exit }
		}
		END { print body }
	' "$EXPORT_SH")"
	# Trim to the "[ ... ]" span and let jq validate/normalise it.
	allowlist_arr="$(printf '%s' "$allowlist_src" | sed -e 's/;.*$//' )"
	if ALLOWLIST_JSON="$(printf '%s' "$allowlist_arr" | jq -c '.' 2>/dev/null)"; then
		ok "parsed $(printf '%s' "$ALLOWLIST_JSON" | jq 'length') allowlisted keys from $EXPORT_SH"
	else
		note "could not parse the def allowlist: block from $EXPORT_SH (allowlist-fidelity legs cannot run)"
		ALLOWLIST_JSON=""
	fi
fi

# Shape buckets (derived from trace-export.sh mapping): which keys legitimately
# ride on which App Insights table. Used by the table-correctness leg.
#   dependencies (RemoteDependencyData) ← tool + lifecycle spans
#   customEvents (EventData)            ← agent + model spans
DEP_KEYS='["gen_ai.tool.name","harness.lifecycle_step","harness.stage","harness.exit_status","harness.duration_ms"]'
EVT_KEYS='["gen_ai.agent.name","gen_ai.operation.name","gen_ai.request.model"]'

is_shippable_key() {
	# arg: key. shippable if in allowlist, or gen_ai.usage. prefix, or a bare
	# measurements-family numeric field.
	local k="$1"
	case "$k" in
		gen_ai.usage.*) return 0 ;;
	esac
	if [ -z "$ALLOWLIST_JSON" ]; then
		return 0 # cannot judge without the allowlist; existence legs already RED
	fi
	if printf '%s' "$ALLOWLIST_JSON" | jq -e --arg k "$k" 'index($k) != null' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# =============================================================================
# A. EXISTENCE
# =============================================================================
WB_TF=""
if [ -d "$TF_DIR" ]; then
	# The workbook resource may live in any *.tf under the module.
	WB_TF="$(grep -rlE '^resource[[:space:]]+"azurerm_application_insights_workbook"' "$TF_DIR" --include='*.tf' 2>/dev/null | head -n1 || true)"
fi
if [ -z "$WB_TF" ]; then
	note "no azurerm_application_insights_workbook resource found under $TF_DIR/*.tf — workbook not authored"
fi
if [ ! -f "$DASH_README" ]; then
	note "missing $DASH_README — dashboard pack undocumented"
fi

# If the workbook TF is absent, the JSON/KQL legs cannot run; emit the summary.
if [ -z "$WB_TF" ]; then
	echo
	if [ "$fail" -ne 0 ]; then
		echo "trace dashboard-pack sensor FAILED (RED) — artifacts absent"
		exit 1
	fi
	echo "trace dashboard-pack checks passed"
	exit 0
fi
ok "workbook Terraform: $WB_TF"

# Exactly one workbook resource.
wb_count="$(grep -cE '^resource[[:space:]]+"azurerm_application_insights_workbook"' "$WB_TF" || true)"
if [ "$wb_count" -ne 1 ]; then
	note "$WB_TF: expected exactly one azurerm_application_insights_workbook, found $wb_count"
fi

# =============================================================================
# F (structural half). Reference module AI resource by Terraform ref; no
# hardcoded connection string / instrumentation key / foreign GUID literal.
# =============================================================================
if ! grep -Eq 'azurerm_application_insights\.[A-Za-z0-9_]+' "$WB_TF"; then
	note "$WB_TF: workbook does not reference the module's App Insights resource (azurerm_application_insights.<name>) by Terraform reference"
fi
# InstrumentationKey / connection-string literals.
if grep -Eiq 'InstrumentationKey=|IngestionEndpoint=|APPLICATIONINSIGHTS_CONNECTION_STRING[[:space:]]*=[[:space:]]*"' "$WB_TF"; then
	note "$WB_TF: contains a connection-string / instrumentation-key literal (must be a Terraform reference, never committed)"
fi
# A bare GUID literal (foreign resource id / iKey) anywhere EXCEPT the workbook
# resource's own `name` attribute — Azure requires the workbook name to be a
# GUID, so that one line is legitimately a literal. Any OTHER GUID (in source_id,
# a data source, or the serialized_data body) is a suspected foreign id / iKey.
if grep -vE '^[[:space:]]*name[[:space:]]*=' "$WB_TF" \
	| grep -Eq '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'; then
	note "$WB_TF: contains a hardcoded GUID literal outside the workbook name= (foreign resource id / iKey suspected — reference the module resource instead)"
fi
# Hardcoded full Azure resource id path.
if grep -Eq '/subscriptions/[0-9a-fA-F-]{8,}' "$WB_TF"; then
	note "$WB_TF: contains a hardcoded /subscriptions/... resource id (must be a Terraform reference)"
fi

# =============================================================================
# Extract the embedded Workbook JSON from serialized_data and enumerate its
# KQL queries. serialized_data is HCL — either a "..." string, a jsonencode({..})
# expression, or a heredoc. We recover the JSON document robustly:
#   1) try jsonencode(...) → not literal JSON, skip to file() / heredoc paths
#   2) try a heredoc (<<-EOT ... EOT) body
#   3) try a quoted JSON string literal (unescape)
# Whatever we recover must jq-parse; if it will not, that is itself a finding.
# =============================================================================
WB_JSON=""
extract_dir="$(mktemp -d)"
trap 'rm -rf "$extract_dir"' EXIT
raw="$extract_dir/serialized.raw"

# Heredoc body (<<EOT / <<-EOT ... EOT) assigned to serialized_data.
awk '
	$0 ~ /serialized_data[[:space:]]*=[[:space:]]*<<-?/ {
		match($0, /<<-?["]?[A-Za-z0-9_]+/)
		tag = substr($0, RSTART, RLENGTH)
		gsub(/[<"-]/, "", tag)
		inhd = 1
		next
	}
	inhd {
		l = $0
		t = l; gsub(/[[:space:]]/, "", t)
		if (t == tag) { inhd = 0; next }
		print l
	}
' "$WB_TF" > "$raw" || true

if [ -s "$raw" ] && jq -e '.' "$raw" >/dev/null 2>&1; then
	WB_JSON="$raw"
	ok "recovered serialized_data from heredoc body"
fi

# jsonencode({ ... }) — HCL, not literal JSON. If present, we cannot jq it
# statically; treat the workbook doc as un-inspectable JSON and surface a
# finding so the implementer supplies an inspectable form (heredoc/file()).
if [ -z "$WB_JSON" ] && grep -Eq 'serialized_data[[:space:]]*=[[:space:]]*jsonencode' "$WB_TF"; then
	note "$WB_TF: serialized_data uses jsonencode(...) — sensor needs a statically inspectable JSON body (heredoc or file(\"...json\")) to lint embedded KQL keys/tables/timespan"
fi

# file("....json") reference.
if [ -z "$WB_JSON" ]; then
	wb_file="$(grep -Eo 'serialized_data[[:space:]]*=[[:space:]]*file\("[^"]+"\)' "$WB_TF" | grep -Eo '"[^"]+"' | tr -d '"' | head -n1 || true)"
	if [ -n "$wb_file" ]; then
		cand="$TF_DIR/$wb_file"
		[ -f "$cand" ] || cand="$wb_file"
		if [ -f "$cand" ] && jq -e '.' "$cand" >/dev/null 2>&1; then
			WB_JSON="$cand"
			ok "recovered serialized_data from file(\"$wb_file\")"
		else
			note "$WB_TF: serialized_data references file(\"$wb_file\") but it is missing or not valid JSON"
		fi
	fi
fi

# Quoted JSON string literal (single-line "..."), best-effort unescape via jq.
if [ -z "$WB_JSON" ]; then
	lit="$(grep -E 'serialized_data[[:space:]]*=[[:space:]]*"' "$WB_TF" | sed -E 's/^[[:space:]]*serialized_data[[:space:]]*=[[:space:]]*//' | head -n1 || true)"
	if [ -n "$lit" ]; then
		if printf '%s' "$lit" | jq -e 'fromjson? | .' >"$extract_dir/lit.json" 2>/dev/null && [ -s "$extract_dir/lit.json" ]; then
			WB_JSON="$extract_dir/lit.json"
			ok "recovered serialized_data from quoted JSON string literal"
		fi
	fi
fi

if [ -z "$WB_JSON" ]; then
	note "$WB_TF: could not recover an inspectable Workbook JSON from serialized_data — KQL key/table/timespan legs cannot run (supply a heredoc or file(\"...json\") body)"
	echo
	echo "trace dashboard-pack sensor FAILED (RED) — artifacts absent/incomplete"
	exit 1
fi

# =============================================================================
# Enumerate the embedded KQL queries. In Workbook JSON, query items carry
# item.content.query (a KQL string) with queryType 0 (Logs). Pull every such
# string; each is one query for the per-query legs (C table, D timespan).
# =============================================================================
queries_file="$extract_dir/queries.txt"
jq -r '.. | objects | .query? // empty | select(type=="string")' "$WB_JSON" > "$queries_file" 2>/dev/null || true
nq="$(grep -c . "$queries_file" || true)"
if [ "$nq" -eq 0 ]; then
	note "$WB_JSON: no embedded KQL queries (.query strings) found — a dashboard pack with no panels charts nothing"
else
	ok "found $nq embedded KQL query string(s)"
fi

# --- B. ALLOWLIST FIDELITY ----------------------------------------------------
# Harvest referenced dimension keys from all queries:
#   customDimensions['key'] / customDimensions["key"] / customDimensions.key
# plus bare gen_ai.* / harness.* tokens appearing in the KQL.
keys_file="$extract_dir/keys.txt"
{
	grep -Eo "customDimensions\[['\"][^'\"]+['\"]\]" "$queries_file" \
		| grep -Eo "['\"][^'\"]+['\"]" | tr -d "\"'"
	grep -Eo 'customDimensions\.[A-Za-z0-9_.]+' "$queries_file" | sed 's/^customDimensions\.//'
	grep -Eo '(gen_ai|harness)\.[A-Za-z0-9_.]+' "$queries_file"
} 2>/dev/null | sort -u > "$keys_file" || true

if [ -n "$ALLOWLIST_JSON" ]; then
	while IFS= read -r k; do
		[ -n "$k" ] || continue
		# `measurements`-family numeric fields ride outside customDimensions;
		# a query naming a measurements column is fine.
		case "$k" in
			measurements*|gen_ai.usage.*) continue ;;
		esac
		if ! is_shippable_key "$k"; then
			note "$WB_JSON: KQL references key '$k' which is NOT in the exporter allowlist / gen_ai.usage. prefix / measurements (the exporter drops it — this charts perpetual nulls)"
		fi
	done < "$keys_file"
fi

# --- C. TABLE CORRECTNESS -----------------------------------------------------
# Per query: the leading source table decides which key shapes are legal.
i=0
while IFS= read -r q; do
	[ -n "$q" ] || continue
	i=$((i + 1))
	# Which App Insights table does this query read from?
	tbl=""
	case "$q" in
		dependencies*|*" dependencies "*|*$'\n'dependencies*) tbl="dependencies" ;;
	esac
	if printf '%s' "$q" | grep -Eq '(^|[^A-Za-z])dependencies([^A-Za-z]|$)'; then tbl="dependencies"; fi
	if printf '%s' "$q" | grep -Eq '(^|[^A-Za-z])customEvents([^A-Za-z]|$)'; then
		if [ -n "$tbl" ]; then
			note "$WB_JSON: query #$i reads BOTH dependencies and customEvents (ambiguous table — tool/lifecycle and agent/model spans live in different tables)"
		fi
		tbl="customEvents"
	fi
	[ -n "$tbl" ] || continue
	# Referenced gen_ai.*/harness.* keys in THIS query.
	qkeys="$(printf '%s' "$q" | grep -Eo '(gen_ai|harness)\.[A-Za-z0-9_.]+' | sort -u || true)"
	while IFS= read -r qk; do
		[ -n "$qk" ] || continue
		case "$qk" in gen_ai.usage.*) continue ;; esac
		if [ "$tbl" = "dependencies" ]; then
			if printf '%s' "$EVT_KEYS" | jq -e --arg k "$qk" 'index($k) != null' >/dev/null 2>&1; then
				note "$WB_JSON: query #$i on 'dependencies' references agent/model-shaped key '$qk' (that key rides customEvents — this query returns empty)"
			fi
		elif [ "$tbl" = "customEvents" ]; then
			if printf '%s' "$DEP_KEYS" | jq -e --arg k "$qk" 'index($k) != null' >/dev/null 2>&1; then
				note "$WB_JSON: query #$i on 'customEvents' references tool/lifecycle-shaped key '$qk' (that key rides dependencies — this query returns empty)"
			fi
		fi
	done <<< "$qkeys"
done < "$queries_file"

# --- D. EXPLICIT-TIMESPAN LINT ------------------------------------------------
# Each query must carry an explicit time bound. Accept a Workbook TimeRange
# parameter binding ({TimeRange}/{TimeRange:query}), an explicit
# timestamp/TimeGenerated comparison, or an ago(...) window.
i=0
while IFS= read -r q; do
	[ -n "$q" ] || continue
	i=$((i + 1))
	bounded=0
	if printf '%s' "$q" | grep -Eq '\{TimeRange'; then bounded=1; fi
	if printf '%s' "$q" | grep -Eq '(timestamp|TimeGenerated)[[:space:]]*(>=|>|between|<=|<)'; then bounded=1; fi
	if printf '%s' "$q" | grep -Eq 'ago\([0-9]'; then bounded=1; fi
	if [ "$bounded" -eq 0 ]; then
		note "$WB_JSON: query #$i sets no explicit timespan (needs {TimeRange} binding, a timestamp/TimeGenerated bound, or ago(...) — the source-span-timestamp gotcha)"
	fi
done < "$queries_file"

# =============================================================================
# E. HONEST METRICS — grep-assert on BOTH the workbook JSON and the README.
# =============================================================================
honesty_targets="$WB_JSON $DASH_README"

# (i) deferred metrics named as unavailable. Look for both deferred concepts
#     (review-blocking findings, per-feature attribution) flagged n/a.
deferred_named=0
for f in $honesty_targets; do
	[ -f "$f" ] || continue
	if grep -Eiq 'review[- ]?blocking' "$f" && grep -Eiq 'per[- ]?feature' "$f"; then
		if grep -Eiq 'deferred|unavailable|not available|n/?a\b' "$f"; then
			deferred_named=1
		fi
	fi
done
if [ "$deferred_named" -eq 0 ]; then
	note "honest-metrics: the pack/README must name the deferred metrics (review-blocking findings AND per-feature attribution) as explicitly unavailable/deferred (checked: $honesty_targets)"
fi

# (ii) NEVER relabel red_reentry_free_rate as "first-pass green".
for f in $honesty_targets; do
	[ -f "$f" ] || continue
	if grep -Eiq 'first[- ]pass green' "$f"; then
		note "honest-metrics: $f uses the forbidden relabel 'first-pass green' (red_reentry_free_rate measures no-red-after-green re-entry, NOT first-pass green)"
	fi
done
# The metric must be named by its honest contract name somewhere in the pack.
reentry_named=0
for f in $honesty_targets; do
	[ -f "$f" ] || continue
	if grep -Eq 'red[_-]reentry[_-]free' "$f"; then reentry_named=1; fi
done
if [ "$reentry_named" -eq 0 ]; then
	note "honest-metrics: neither the workbook nor $DASH_README names red_reentry_free_rate by its honest contract name"
fi

# =============================================================================
# G. TERRAFORM FMT (+ best-effort validate only if initialised).
# =============================================================================
if command -v terraform >/dev/null 2>&1; then
	if [ -d "$TF_DIR" ]; then
		if ! terraform fmt -check -recursive "$TF_DIR" >/dev/null 2>&1; then
			note "terraform fmt drift under $TF_DIR — run: terraform fmt -recursive $TF_DIR"
		fi
		if [ -d "$TF_DIR/.terraform" ]; then
			if ! terraform -chdir="$TF_DIR" validate >/dev/null 2>&1; then
				note "terraform validate failed under $TF_DIR"
			fi
		else
			echo "SKIP: $TF_DIR/.terraform absent — validate not exercised (fmt-check only)"
		fi
	fi
else
	echo "SKIP: terraform not installed — fmt/validate gate not exercised"
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "trace dashboard-pack sensor FAILED (RED)"
	exit 1
fi
echo "trace dashboard-pack checks passed"
