#!/usr/bin/env bash
# test_trace_dashboard_pack.sh — RED regression sensor (issue #113, feature
# harness-quality-workbook). This sensor IS the executable spec for the
# live-deployed Azure Workbook dashboard pack. It stays RED until the
# implementer authors BOTH artifacts:
#
#   1. a Terraform file under infra/terraform/ declaring an
#      `azurerm_application_insights_workbook` resource whose `data_json`
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

# Correct provider argument name. azurerm_application_insights_workbook REQUIRES
# `data_json` (not `serialized_data`, which belongs to a different resource and
# fails `terraform validate` at deploy time). CI has no Azure provider so it
# cannot run `terraform validate` — this static grep catches the schema error
# that fmt-check alone lets through.
if ! grep -Eq '^[[:space:]]*data_json[[:space:]]*=' "$WB_TF"; then
	note "$WB_TF: workbook is missing the required 'data_json' argument (azurerm_application_insights_workbook uses data_json, not serialized_data)"
fi
if grep -Eq '^[[:space:]]*serialized_data[[:space:]]*=' "$WB_TF"; then
	note "$WB_TF: uses 'serialized_data' — that argument does not exist on azurerm_application_insights_workbook (it is 'data_json') and will fail terraform validate/apply"
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
# a data source, or the data_json body) is a suspected foreign id / iKey.
if grep -vE '^[[:space:]]*name[[:space:]]*=' "$WB_TF" \
	| grep -Eq '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'; then
	note "$WB_TF: contains a hardcoded GUID literal outside the workbook name= (foreign resource id / iKey suspected — reference the module resource instead)"
fi
# Hardcoded full Azure resource id path.
if grep -Eq '/subscriptions/[0-9a-fA-F-]{8,}' "$WB_TF"; then
	note "$WB_TF: contains a hardcoded /subscriptions/... resource id (must be a Terraform reference)"
fi

# =============================================================================
# Extract the embedded Workbook JSON from data_json and enumerate its
# KQL queries. data_json is HCL — either a "..." string, a jsonencode({..})
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

# Heredoc body (<<EOT / <<-EOT ... EOT) assigned to data_json.
awk '
	$0 ~ /data_json[[:space:]]*=[[:space:]]*<<-?/ {
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
	ok "recovered data_json from heredoc body"
fi

# jsonencode({ ... }) — HCL, not literal JSON. If present, we cannot jq it
# statically; treat the workbook doc as un-inspectable JSON and surface a
# finding so the implementer supplies an inspectable form (heredoc/file()).
if [ -z "$WB_JSON" ] && grep -Eq 'data_json[[:space:]]*=[[:space:]]*jsonencode' "$WB_TF"; then
	note "$WB_TF: data_json uses jsonencode(...) — sensor needs a statically inspectable JSON body (heredoc or file(\"...json\")) to lint embedded KQL keys/tables/timespan"
fi

# file("....json") reference.
if [ -z "$WB_JSON" ]; then
	wb_file="$(grep -Eo 'data_json[[:space:]]*=[[:space:]]*file\("[^"]+"\)' "$WB_TF" | grep -Eo '"[^"]+"' | tr -d '"' | head -n1 || true)"
	if [ -n "$wb_file" ]; then
		cand="$TF_DIR/$wb_file"
		[ -f "$cand" ] || cand="$wb_file"
		if [ -f "$cand" ] && jq -e '.' "$cand" >/dev/null 2>&1; then
			WB_JSON="$cand"
			ok "recovered data_json from file(\"$wb_file\")"
		else
			note "$WB_TF: data_json references file(\"$wb_file\") but it is missing or not valid JSON"
		fi
	fi
fi

# Quoted JSON string literal (single-line "..."), best-effort unescape via jq.
if [ -z "$WB_JSON" ]; then
	lit="$(grep -E 'data_json[[:space:]]*=[[:space:]]*"' "$WB_TF" | sed -E 's/^[[:space:]]*data_json[[:space:]]*=[[:space:]]*//' | head -n1 || true)"
	if [ -n "$lit" ]; then
		if printf '%s' "$lit" | jq -e 'fromjson? | .' >"$extract_dir/lit.json" 2>/dev/null && [ -s "$extract_dir/lit.json" ]; then
			WB_JSON="$extract_dir/lit.json"
			ok "recovered data_json from quoted JSON string literal"
		fi
	fi
fi

if [ -z "$WB_JSON" ]; then
	note "$WB_TF: could not recover an inspectable Workbook JSON from data_json — KQL key/table/timespan legs cannot run (supply a heredoc or file(\"...json\") body)"
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

# --- #139: a skill-usage panel must surface harness.skill.name ---------------
if grep -q 'harness\.skill\.name' "$queries_file"; then
	ok "workbook carries a skill-usage panel referencing harness.skill.name (#139)"
else
	note "$WB_JSON: no panel references harness.skill.name — skill usage (#139) is not surfaced in the dashboard"
fi

# =============================================================================
# #222 — workbook redesign Tabs 0-1. The workbook's primary job is to monitor
# each issue's run, but the original pack was 100% by_version aggregates with
# zero per-issue view. This leg pins the Tabs 0-1 redesign: a tab container, a
# fleet-health in-flight tile (started, no finish — previously invisible), an
# issue-run grid keyed on the mandatory harness.issue field, and the {Issue}
# drill-through parameter export Tab 2 will consume.
# =============================================================================
# Tab container: restructured into tabs — a links item styled as tabs driving a
# selectedTab parameter. A flat single-page workbook fails this.
if grep -Eq '"style"[[:space:]]*:[[:space:]]*"tabs"' "$WB_JSON" && grep -q 'selectedTab' "$WB_JSON"; then
	ok "#222: workbook restructured into tabs (links item styled tabs drives selectedTab)"
else
	note "$WB_JSON: workbook is not restructured into tabs (need a links item with \"style\":\"tabs\" driving a selectedTab parameter) — #222 Tab container"
fi

# Tab 0 fleet health: in-flight runs (counted at worktree_create, no finish span
# yet) must be surfaced — the new visibility. One query references BOTH
# worktree_create and an in_flight / in-flight count. Match against a flattened
# whole-query stream so a future multi-line KQL edit cannot silently pass.
qflat="$extract_dir/queries.flat"
jq -r '.. | objects | .query? // empty | select(type=="string") | gsub("[[:space:]]+"; " ")' "$WB_JSON" > "$qflat" 2>/dev/null || true
if grep 'worktree_create' "$qflat" | grep -Eq 'in[_-]flight'; then
	ok "#222: fleet-health surfaces in-flight runs (worktree_create without finish)"
else
	note "$WB_JSON: no fleet-health tile surfaces in-flight runs (a query over worktree_create producing an in_flight / in-flight count) — #222 Tab 0"
fi

# Tab 1 issue-run grid: one row per issue run — a query keyed on the mandatory
# harness.issue field (summarize ... by issue). Every original panel ignored it.
if grep -F "customDimensions['harness.issue']" "$qflat" | grep -Eq 'by[[:space:]]+issue' ; then
	ok "#222: issue-run grid groups by harness.issue (per-issue view)"
else
	note "$WB_JSON: no panel builds a per-issue-run grid keyed on harness.issue (summarize ... by issue) — #222 Tab 1"
fi

# Drill-through: Tab 1 row-click exports an {Issue} parameter (the wiring Tab 2
# depends on) — an Issue parameter is declared AND a grid exports to it.
dt_param=0
grep -Eq '"name"[[:space:]]*:[[:space:]]*"Issue"' "$WB_JSON" && dt_param=1
dt_export=0
grep -Eq '"(exportParameterName|parameterName)"[[:space:]]*:[[:space:]]*"Issue"' "$WB_JSON" && dt_export=1
if [ "$dt_param" -eq 1 ] && [ "$dt_export" -eq 1 ]; then
	ok "#222: Tab 1 exports the {Issue} parameter on row selection (drill-through wiring)"
else
	note "$WB_JSON: Tab 1 issue-run grid does not export an {Issue} parameter (declare an Issue parameter AND set the grid's exported parameter) — #222 drill-through"
fi

# =============================================================================
# #223 — Tab 2 "Single-run drill-down" container. #222 wired the {Issue}
# drill-through export; this feature adds the tab that consumes it. Mirrors the
# #222 tab mechanism exactly: a links (type:11 "tabs") subTarget entry writing
# selectedTab, plus a type:12 group gated via conditionalVisibility on
# selectedTab. This leg pins BOTH halves of the container:
#   (1) the tabs links component carries a subTarget:"drilldown" entry
#       positioned BETWEEN the issues and compare entries, AND
#   (2) a type:12 group whose conditionalVisibility.value == "drilldown"
#       exists and carries a header text item (type:1) that names {Issue}.
# A flat pack, or a drilldown entry appended out of order, or a group with no
# {Issue} header, must fail — the tab that consumes the drill-through is absent.
# =============================================================================
# (1) drilldown links entry, ordered between issues and compare (all jq logic,
#     so a null index cannot become a false pass).
dd_between="$(jq -r '
	[.items[] | select(.name == "tabs") | .content.links[].subTarget] as $s
	| ($s | index("drilldown")) as $d
	| ($s | index("issues")) as $i
	| ($s | index("compare")) as $c
	| ($d != null and $i != null and $c != null and $i < $d and $d < $c)
' "$WB_JSON" 2>/dev/null || echo false)"
if [ "$dd_between" = "true" ]; then
	ok "#223: tabs carries a 'drilldown' subTarget positioned between issues and compare"
else
	note "$WB_JSON: tabs links component has no subTarget:\"drilldown\" entry positioned between the issues and compare entries — #223 Tab 2 container"
fi

# (2) a type:12 group gated on selectedTab == "drilldown" carrying a header text
#     item that names {Issue}.
dd_group_hdr="$(jq -r '
	[ .items[]
	  | select(.type == 12 and .conditionalVisibility.value == "drilldown")
	  | .content.items[]?
	  | select(.type == 1)
	  | .content.json
	  | select(type == "string" and test("Issue")) ] | length
' "$WB_JSON" 2>/dev/null || echo 0)"
if [ "${dd_group_hdr:-0}" -gt 0 ]; then
	ok "#223: drilldown group (conditionalVisibility == drilldown) has a header text item naming {Issue}"
else
	note "$WB_JSON: no type:12 group gated on selectedTab == \"drilldown\" with a header text item referencing {Issue} — #223 Tab 2 container"
fi

# #223 panel 1 — lifecycle-step timeline. The drill-down tab must carry a KQL
# panel that renders the selected run's lifecycle as a time-ordered table: a
# dependencies query scoped to the exported {Issue} on harness.issue, reading
# harness.lifecycle_step, ordered by timestamp ascending. Extract ONLY the
# tab-drilldown group's KqlItem (type:3) query strings — flattened one-per-line
# — so a compare-tab or fleet-health query cannot satisfy this by accident, and
# require a single query to carry all three markers (issue filter + lifecycle
# step + timestamp ordering) at once.
dd_timeline="$extract_dir/drilldown-queries.flat"
jq -r '
	.items[]
	| select(.type == 12 and .conditionalVisibility.value == "drilldown")
	| .content.items[]?
	| select(.type == 3)
	| .content.query? // empty
	| select(type == "string")
	| gsub("[[:space:]]+"; " ")
' "$WB_JSON" > "$dd_timeline" 2>/dev/null || true
if grep -F "customDimensions['harness.issue']" "$dd_timeline" \
	| grep -F '{Issue}' \
	| grep -F 'harness.lifecycle_step' \
	| grep -Eiq 'order by timestamp'; then
	ok "#223: drilldown tab carries a lifecycle-step timeline for {Issue} (panel 1)"
else
	note "$WB_JSON: no lifecycle-step timeline for {Issue} — #223 panel 1 (need a tab-drilldown KqlItem: dependencies filtered on harness.issue == '{Issue}', referencing harness.lifecycle_step, order by timestamp)"
fi

# #223 panel 2 — per-feature TDD-loop strip. The drill-down tab must also carry
# a KQL panel that summarises each feature's RED/GREEN churn for the selected
# run: a dependencies query scoped to the exported {Issue} on harness.issue,
# grouped by feature (harness.feature_id), counting the loop steps
# red_handback / impl_handback / green_handback (role attribution rides on
# harness.subagent, not the un-allowlisted harness.role). Reuse the same
# flattened tab-drilldown query lines and require a single query to carry ALL
# the markers (issue filter + feature_id + all three handback step names) so the
# lifecycle-timeline query — which names harness.lifecycle_step but neither
# feature_id nor the handback trio — cannot satisfy this by accident.
if grep -F "customDimensions['harness.issue']" "$dd_timeline" \
	| grep -F '{Issue}' \
	| grep -F 'harness.feature_id' \
	| grep -F 'red_handback' \
	| grep -F 'impl_handback' \
	| grep -Fq 'green_handback'; then
	ok "#223: drilldown tab carries a per-feature TDD loop strip for {Issue} (panel 2)"
else
	note "$WB_JSON: no per-feature TDD loop strip for {Issue} — #223 panel 2 (need a tab-drilldown KqlItem: dependencies filtered on harness.issue == '{Issue}', grouped by harness.feature_id, counting red_handback/impl_handback/green_handback)"
fi

# #223 panel 3 — per-run tool/skill calls. The drill-down tab must also carry a
# KQL panel that surfaces the selected run's tool and skill invocations: a
# dependencies query scoped to the exported {Issue} on harness.issue that
# references BOTH gen_ai.tool.name (tool calls) AND harness.skill.name (skill
# calls) — the volume/failures/top-durations view. Reuse the same flattened
# tab-drilldown query lines and require a single query to carry ALL the markers
# (issue filter + both the tool-name and skill-name dimensions) so the
# lifecycle-timeline query (harness.lifecycle_step) and the TDD-loop strip
# (harness.feature_id) — neither of which names both tool and skill — cannot
# satisfy this by accident.
if grep -F "customDimensions['harness.issue']" "$dd_timeline" \
	| grep -F '{Issue}' \
	| grep -F 'gen_ai.tool.name' \
	| grep -Fq 'harness.skill.name'; then
	ok "#223: drilldown tab carries a per-run tool/skill calls panel for {Issue} (panel 3)"
else
	note "$WB_JSON: no per-run tool/skill panel for {Issue} — #223 panel 3 (need a tab-drilldown KqlItem: dependencies filtered on harness.issue == '{Issue}', referencing gen_ai.tool.name AND harness.skill.name, for call volume/failures/top-durations)"
fi

# #223 panel 5 — per-run cost strip. The drill-down tab must ALSO carry a KQL
# panel that surfaces the selected run's model token cost. UNLIKE panels 1-3
# (which read the dependencies table) this panel queries the customEvents table
# — that is where the exporter maps agent+model spans — scoped to the exported
# {Issue} on harness.issue, and it must emit a tokens_status honesty column so a
# run whose model spans carried no gen_ai.usage.* is reported as unavailable
# rather than a fabricated 0. Reuse the same flattened tab-drilldown query lines
# and require a single query to carry ALL the markers (customEvents table +
# issue filter + tokens_status) so the dependencies-based panels 1-3 — none of
# which name the customEvents table — cannot satisfy this by accident.
if grep -F 'customEvents' "$dd_timeline" \
	| grep -F "customDimensions['harness.issue']" \
	| grep -F '{Issue}' \
	| grep -Fq 'tokens_status'; then
	ok "#223: drilldown tab carries a per-run cost strip for {Issue} (panel 5)"
else
	note "$WB_JSON: no per-run cost strip with tokens_status for {Issue} — #223 panel 5 (need a tab-drilldown KqlItem: customEvents filtered on harness.issue == '{Issue}', tokens by agent/model, emitting a tokens_status column that reads 'unavailable' when no model span carried gen_ai.usage.*)"
fi

# #223 panel 6 — end-to-end transaction deep link (link-OUT, NOT a re-built
# waterfall). The drill-down tab must hand the operator across to the NATIVE
# App Insights end-to-end transaction view for the selected run, keyed on
# operation_Id == 'issue-{Issue}'. This is a deep link, not a KQL panel: the
# tab must NOT re-implement the transaction waterfall in KQL (which would need
# parent_span_id to reconstruct the span tree). Two halves:
#   (a) the tab-drilldown group carries a link-OUT item (a type:11 LinksItem
#       whose linkTarget is not the internal "parameter" tab-switch, or a grid
#       link-formatter column — both surface as a linkTarget != "parameter")
#       whose serialized content references operation_Id and/or issue-{Issue},
#       AND
#   (b) NO tab-drilldown KqlItem query rebuilds the waterfall — the flattened
#       drilldown query lines must NOT reference parent_span_id.
# (a) link-OUT item keyed on the run. Collect drilldown items that carry any
#     non-"parameter" linkTarget (type:11 url link OR grid link formatter), then
#     grep their serialized form for the run key — a plain KQL panel (no
#     linkTarget) cannot satisfy this by accident.
dd_deeplink="$extract_dir/drilldown-linkouts.json"
jq -c '
	.items[]
	| select(.type == 12 and .conditionalVisibility.value == "drilldown")
	| .content.items[]?
	| select([.. | objects | select(has("linkTarget") and (.linkTarget != "parameter"))] | length > 0)
' "$WB_JSON" > "$dd_deeplink" 2>/dev/null || true
if [ -s "$dd_deeplink" ] && grep -Eq 'operation_Id|issue-\{Issue\}' "$dd_deeplink"; then
	ok "#223: drilldown tab carries a transaction-view deep link keyed on operation_Id/issue-{Issue} (panel 6)"
else
	note "no transaction-view deep link keyed on operation_Id/issue-{Issue} — #223 panel 6 (need a tab-drilldown link-OUT: a type:11 LinksItem or grid link-formatter column, linkTarget != \"parameter\", opening the native App Insights end-to-end transaction view for operation_Id == 'issue-{Issue}')"
fi
# (b) waterfall NOT rebuilt in KQL. Reuse the flattened tab-drilldown query
#     lines ($dd_timeline, one query per line) and require that NONE reference
#     parent_span_id — the native transaction view owns the span tree.
if grep -Fq 'parent_span_id' "$dd_timeline"; then
	note "$WB_JSON: a tab-drilldown KqlItem query references parent_span_id — Tab 2 must NOT rebuild the end-to-end transaction waterfall in KQL; link OUT to the native App Insights transaction view instead — #223 panel 6"
else
	ok "#223: Tab 2 does not rebuild the transaction waterfall in KQL (no parent_span_id in drilldown queries)"
fi

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

# (i-b) #171: no stale "until #96" token-gap pointer. #96 (Claude Code adapter)
#       is CLOSED and its hook emits gen_ai.usage.* — the remaining token/cost
#       gap is Copilot-side, tracked in #163. The token panel must say so.
for f in $honesty_targets; do
	[ -f "$f" ] || continue
	if grep -Eiq 'until[- ](issue-)?#?96' "$f"; then
		note "honest-metrics: $f still points at #96 as the token-gap blocker — #96 is closed and its adapter emits gen_ai.usage.*; the honest remaining gap is Copilot-side (#163)"
	fi
done
token_gap_pointer=0
for f in $honesty_targets; do
	[ -f "$f" ] || continue
	if grep -Eq '#163|issue-163' "$f"; then token_gap_pointer=1; fi
done
if [ "$token_gap_pointer" -eq 0 ]; then
	note "honest-metrics: neither the workbook nor $DASH_README points at #163 for the remaining Copilot-side token/cost gap"
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
