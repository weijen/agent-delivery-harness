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

# #225 F1 panel 4 — failure-detail log panel over the `traces` table (the WHY).
# The drill-down tab must ALSO carry a KQL panel that surfaces the selected
# run's gate/sensor FAILURE log records with their captured output. UNLIKE the
# dependencies panels 1-3 and the customEvents cost strip (panel 5), this panel
# queries the `traces` table — the log stream's landing table (App-Insights
# MessageData, per #220's logmap.py) — scoped to the selected run via the native
# `operation_Id == 'issue-{Issue}'` correlation key, filtered to FAILURE records
# (`severityLevel` >= 3 AND customDimensions['harness.outcome'] == 'fail'),
# projecting the captured `message`, and correlated to the failing span via the
# native traces column `operation_ParentId` — NEVER `parent_span_id` (the
# panel-6 waterfall leg below forbids rebuilding the span tree in KQL). Reuse
# the same flattened tab-drilldown query lines and require a SINGLE query to
# carry ALL the markers at once (traces table + operation_Id/issue- filter +
# operation_ParentId correlation + severityLevel + harness.outcome + message) so
# the dependencies/customEvents panels 1-3,5 — none of which name the traces
# table or operation_ParentId — cannot satisfy this by accident.
if grep -F 'traces' "$dd_timeline" \
	| grep -F 'operation_Id' \
	| grep -F 'issue-' \
	| grep -F 'operation_ParentId' \
	| grep -F 'severityLevel' \
	| grep -F "customDimensions['harness.outcome']" \
	| grep -Fq 'message'; then
	ok "#225: drilldown tab carries a failure-detail log panel over 'traces' for {Issue} (panel 4)"
else
	note "$WB_JSON: no failure-detail log panel over 'traces' for {Issue} — #225 panel 4 (need a tab-drilldown KqlItem: traces filtered on operation_Id == 'issue-{Issue}', severityLevel >= 3 AND customDimensions['harness.outcome'] == 'fail', projecting message, correlated to the failing span via operation_ParentId — NOT parent_span_id)"
fi

# #225 F2 panel 4 — explicit `log evidence unavailable` empty-state (never an
# empty chart, never inferred health). Azure Workbook conditionalVisibility can
# only key off PARAMETERS, not a query's row count, so a plain projection over
# the `traces` table returns ZERO rows on a run with no failure logs — an empty
# grid that silently reads as "healthy". The F1 panel must therefore self-render
# an honest empty-state via an always-one-row construct that mirrors the
# existing tokens_status = iff(...) honesty columns: `union` the real failure
# records with a synthetic placeholder row that is filtered in ONLY when the
# failure set is empty (`toscalar(... | count) == 0`), the placeholder carrying
# the literal `log evidence unavailable`. Reuse the same flattened tab-drilldown
# query lines ($dd_timeline, one query per line) and require the SAME failure-
# detail query (scoped by its identity markers: the `traces` table +
# `operation_ParentId` span correlation, which no other drilldown panel carries)
# to ALSO carry ALL of the honest empty-state markers at once — the literal
# `log evidence unavailable`, the `union` always-one-row construct, and the
# `toscalar(... count ...) == 0` empty-set guard — so a plain F1 projection
# (traces | where ... | project ...) that lacks the union/toscalar guard cannot
# satisfy this by accident, and no non-traces panel can either.
if grep -F 'traces' "$dd_timeline" \
	| grep -F 'operation_ParentId' \
	| grep -F 'log evidence unavailable' \
	| grep -F 'union' \
	| grep -F 'toscalar' \
	| grep -F 'count' \
	| grep -Fq '== 0'; then
	ok "#225: failure-detail log panel renders an explicit 'log evidence unavailable' empty-state via an always-one-row union/toscalar guard (panel 4, F2)"
else
	note "$WB_JSON: failure-detail log panel has no explicit 'log evidence unavailable' empty-state — #225 F2 (the traces/operation_ParentId panel must emit an always-one-row honesty construct: union the failure records with a synthetic placeholder row gated by toscalar(<failures> | count) == 0, the placeholder carrying the literal 'log evidence unavailable' — a plain projection returns an empty grid on a run with no failure logs)"
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

# #223: transaction deep-link uses substitutable {Issue} token. The
# drilldown-transaction-deeplink item's cellValue is a portal URL whose query
# embeds the run key. Azure Workbook parameter substitution ONLY matches a
# LITERAL {Issue} (or {Issue:urlencode}) token — a percent-encoded %7BIssue%7D
# is NEVER substituted and will always query the literal string "issue-%7BIssue%7D".
# Assert: (1) cellValue contains a literal (un-encoded) {Issue token, AND
#         (2) cellValue does NOT contain the percent-encoded %7BIssue%7D form.
dd_cellvalue="$(jq -r '
	.. | objects
	| select(.name? == "drilldown-transaction-deeplink")
	| .content.links[]?
	| select(.id? == "drilldown-transaction-deeplink")
	| .cellValue
	| select(type == "string")
' "$WB_JSON" 2>/dev/null || true)"
dd_has_literal=0
dd_has_encoded=0
if printf '%s' "$dd_cellvalue" | grep -Fq '{Issue'; then dd_has_literal=1; fi
if printf '%s' "$dd_cellvalue" | grep -Fq '%7BIssue%7D'; then dd_has_encoded=1; fi
if { [ "$dd_has_literal" -eq 1 ] && [ "$dd_has_encoded" -eq 0 ]; }; then
	ok "#223: transaction deep-link cellValue uses a substitutable literal {Issue} token (not percent-encoded)"
else
	note "#223: transaction deep-link cellValue must contain a literal {Issue} token (not percent-encoded %7BIssue%7D) — Azure Workbook only substitutes {Issue} or {Issue:urlencode}, never %7BIssue%7D; has_literal=$dd_has_literal has_encoded=$dd_has_encoded"
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
# #225 F3: SHIPPED log panel + map coherence. The failure-detail LOG panel
# (Tab 2 panel 4) is now SHIPPED — the #219 log-schema (log-schema.v1.json)
# gives the detail stream, #220's logmap is MERGED, so the deferred/#220-gated
# posture is retired. Honesty doctrine: the README panel->contract map must
# document it as a SHIPPED row, not silently omit it and not leave stale
# deferred language. This leg guards the README MAP surface: (a) the
# "Panel -> contract-field map" section must carry a *Failure-detail log panel*
# row that names the `traces` table, references the #219 `log-schema.v1.json`
# contract, names the log-schema fields the panel keys on (message, level,
# harness.issue, harness.stage, harness.outcome, and the span_id correlation
# id — all REAL keys in docs/evaluation/log-schema.v1.json), and states the
# honest `log evidence unavailable` caveat — with NO leftover deferred/#220
# language on that row; AND (b) that same map must carry a row for EVERY shipped
# Tab 2 panel (now six, incl. the log panel), so the shipped log row lands
# beside a complete Tab 2 panel map. (c) The stale log-panel deferral prose
# (`#220`-gated) must be GONE from the whole README — #220 is only ever the log
# panel's gate here, so its removal proves the deferred→shipped flip landed in
# the narrative too. Scope the row assertions strictly to the map section (its
# heading to the next top-level "## " heading) so the tabs-list bullet cannot
# satisfy a row assertion by accident.
map_section="$extract_dir/readme-panel-map.section"
if [ -f "$DASH_README" ]; then
	awk '
		/^## Panel -> contract-field map/ { grab = 1; next }
		grab && /^## / { grab = 0 }
		grab { print }
	' "$DASH_README" > "$map_section" 2>/dev/null || true
else
	: > "$map_section"
fi
# (a) a map TABLE row documenting the SHIPPED failure-detail LOG panel.
log_row_line=""
while IFS= read -r map_line; do
	case "$map_line" in
	'|'*) : ;;
	*) continue ;;
	esac
	if printf '%s\n' "$map_line" | grep -Fq 'Failure-detail log panel'; then
		log_row_line="$map_line"
	fi
done < "$map_section"
log_row_shipped=1
if [ -z "$log_row_line" ]; then
	note "#225 F3: the README panel->contract map has no 'Failure-detail log panel' row — the SHIPPED Tab 2 panel 4 must be named in the map itself, not just the tabs bullet"
	log_row_shipped=0
else
	# must name the traces table (word-bounded so it is the App Insights table).
	if ! printf '%s\n' "$log_row_line" | grep -Eiwq 'traces'; then
		note "#225 F3: the 'Failure-detail log panel' map row does not name the 'traces' table — the shipped log panel queries the App Insights traces table"
		log_row_shipped=0
	fi
	# must reference the #219 log-schema contract doc.
	if ! printf '%s\n' "$log_row_line" | grep -Fq 'log-schema.v1.json'; then
		note "#225 F3: the 'Failure-detail log panel' map row does not reference 'log-schema.v1.json' — the shipped log panel keys off the #219 log-schema contract"
		log_row_shipped=0
	fi
	# must name each log-schema field the panel keys on (all REAL keys in
	# docs/evaluation/log-schema.v1.json: message/level/harness.issue required,
	# harness.stage/harness.outcome/span_id optional).
	for log_key in message level harness.issue harness.stage harness.outcome span_id; do
		if ! printf '%s\n' "$log_row_line" | grep -Fiwq "$log_key"; then
			note "#225 F3: the 'Failure-detail log panel' map row omits the log-schema key '$log_key' (a real field in docs/evaluation/log-schema.v1.json the shipped panel keys on)"
			log_row_shipped=0
		fi
	done
	# must carry the honest 'log evidence unavailable' empty-state caveat.
	if ! printf '%s\n' "$log_row_line" | grep -Fiq 'log evidence unavailable'; then
		note "#225 F3: the 'Failure-detail log panel' map row lacks the honest 'log evidence unavailable' caveat — the shipped panel must promise an explicit empty-state, never an empty chart"
		log_row_shipped=0
	fi
	# the OLD deferred/#220-gated posture for THIS panel must be gone from the row.
	if printf '%s\n' "$log_row_line" | grep -Eiq 'deferred|gated on #?220|#?220[- ]gated'; then
		note "#225 F3: the 'Failure-detail log panel' map row still marks the panel deferred/#220-gated — it must document the SHIPPED state (traces + log-schema.v1.json keys + honest unavailable caveat)"
		log_row_shipped=0
	fi
fi
# (b) every shipped Tab 2 panel appears as a row in that same map section — now
#     including the SHIPPED failure-detail log panel (a 6th Tab 2 row).
missing_tab2_panel=""
for tab2_panel in \
	"Lifecycle step timeline" \
	"Per-feature TDD loop strip" \
	"Tool & skill calls" \
	"Cost strip" \
	"Transaction-view deep link" \
	"Failure-detail log panel"; do
	if ! grep -Fq "$tab2_panel" "$map_section"; then
		missing_tab2_panel="$tab2_panel"
	fi
done
if [ -n "$missing_tab2_panel" ]; then
	note "#225 F3: the README panel->contract map is missing a row for a shipped Tab 2 panel ('$missing_tab2_panel') — the shipped log row must sit beside a complete Tab 2 panel map"
fi
# (c) the stale log-panel deferral prose (#220-gated) must be gone README-wide.
#     Match only the STALE forms (word-boundaried) — `#220` as an issue token,
#     `gated on #?220`, or `220[- ]gated` — so a bare `220` substring in an
#     unrelated future token (e.g. `8220`, issue `#2200`) does not false-trip.
readme_220=0
if [ -f "$DASH_README" ] && grep -Eiq '#220\b|gated on #?220|220[- ]gated' "$DASH_README"; then
	readme_220=1
	note "#225 F3: $DASH_README still references #220 for the failure-detail log panel — the deferred→shipped flip must drop the '#220-gated' / 'deferred to a #220-gated issue' language from the narrative and map"
fi
if [ "$log_row_shipped" -eq 1 ] && [ -z "$missing_tab2_panel" ] && [ "$readme_220" -eq 0 ]; then
	ok "#225 F3: README panel map documents the SHIPPED failure-detail log panel (traces + log-schema.v1.json keys + honest unavailable caveat), rows every shipped Tab 2 panel, and carries no stale #220 deferral"
fi

# =============================================================================
# #225 F3 (workbook JSON): the SHIPPED failure-detail log panel means the
# workbook's OWN drill-down header must NOT still carry the retired,
# `#220`-gated / "not shipped in this tab" log-panel deferral. The README-wide
# guard above never scanned the embedded Workbook JSON, so a stale header
# sentence there could contradict the shipped `drilldown-failure-detail-log`
# panel unseen. `#220` appears in the workbook ONLY as this log panel's stale
# gate, so a workbook-wide `#?220` absence check is specific and safe.
# Scope note: the LEGITIMATE `deferred-metrics` text item (review-blocking
# findings + per-feature attribution marked "Deferred / unavailable") carries
# NO `#220` and NO "not shipped in this tab", so this leg targets ONLY the
# log-panel deferral and does NOT trip on that block.
wb_log_defer=0
if grep -Eiq '#?220' "$WB_JSON"; then
	wb_log_defer=1
	note "#225 F3: $WB_JSON still references #220 — the drill-down header's stale '(gated on #220)' log-panel deferral must be dropped now that the failure-detail log panel ships (the legitimate deferred-metrics block carries no #220)"
fi
if grep -Fq 'not shipped in this tab' "$WB_JSON"; then
	wb_log_defer=1
	note "#225 F3: $WB_JSON still says the log panel is 'not shipped in this tab' — the failure-detail log panel IS shipped; drop the stale deferral prose from the drill-down header"
fi
if grep -Eiq 'log[*[:space:]]*panel is deferred' "$WB_JSON"; then
	wb_log_defer=1
	note "#225 F3: $WB_JSON still says the failure-detail log panel 'is deferred' — the panel ships; the drill-down header must not mark it deferred/unavailable"
fi
if [ "$wb_log_defer" -eq 0 ]; then
	ok "#225 F3: the workbook JSON drill-down header carries no stale #220 / 'not shipped in this tab' / 'log panel is deferred' deferral (the shipped failure-detail log panel is not contradicted; the legitimate deferred-metrics block is untouched)"
fi

# =============================================================================
# #224 — compare-base-query-hoist. The 8 by-version panels under the
# tab-compare group each inlined the identical prelude
#   extend hv = tostring(customDimensions['harness.version'])
# The refactor hoists that shared extend into ONE base fragment parameter per
# source table — CmpDepBase for the 7 panels reading the `dependencies` table
# (pass-rate, red-reentry-free-rate, deviation-rate, tool-call-volume,
# skill-invocation-volume, wall-clock-per-step, failure-mode) and CmpEvtBase for
# the 1 panel reading `customEvents` (token-cost) — whose value string carries
# the extend. Each panel then references its table's fragment via {CmpDepBase} /
# {CmpEvtBase} and NO LONGER inlines the literal extend. This leg pins the hoist:
#   (1) a workbook parameter CmpDepBase AND one CmpEvtBase exist, each value
#       carrying `extend hv = tostring(customDimensions['harness.version'])`;
#   (2) every one of the 8 tab-compare panels REFERENCES its table's fragment
#       token ({CmpDepBase} for the 7 dependencies panels, {CmpEvtBase} for the
#       customEvents token-cost panel) AND no longer inlines the literal extend;
#   (3) the hoisted fragment does not smuggle a non-allowlisted key — harvest
#       its customDimensions keys and run them through the SAME is_shippable_key
#       allowlist mechanism the B leg uses.
# Everything reads ONLY the tab-compare group, so fleet/issues/drilldown panels
# cannot false-satisfy it.
# =============================================================================
HV_EXTEND="extend hv = tostring(customDimensions['harness.version'])"
cmp_hoist_ok=1

# (1) base fragment parameters exist, each carrying the hoisted extend.
cmp_dep_frag="$(jq -r '[.. | objects | select(.name? == "CmpDepBase") | .value | if type == "string" then . else tojson end] | .[0] // ""' "$WB_JSON" 2>/dev/null || echo "")"
cmp_evt_frag="$(jq -r '[.. | objects | select(.name? == "CmpEvtBase") | .value | if type == "string" then . else tojson end] | .[0] // ""' "$WB_JSON" 2>/dev/null || echo "")"
if ! printf '%s' "$cmp_dep_frag" | grep -Fq "$HV_EXTEND"; then
	note "$WB_JSON: no CmpDepBase base fragment parameter carrying '$HV_EXTEND' — the 7 tab-compare dependencies panels' shared extend is not hoisted (#224)"
	cmp_hoist_ok=0
fi
if ! printf '%s' "$cmp_evt_frag" | grep -Fq "$HV_EXTEND"; then
	note "$WB_JSON: no CmpEvtBase base fragment parameter carrying '$HV_EXTEND' — the tab-compare customEvents (token-cost) panel's shared extend is not hoisted (#224)"
	cmp_hoist_ok=0
fi

# (2) every tab-compare panel references its table's fragment token and no
#     longer inlines the literal extend. Flatten each panel's query to one line
#     (name<TAB>query) so a multi-line KQL edit cannot slip past.
cmp_panels="$extract_dir/compare-panels.flat"
jq -r '
	.items[]
	| select(.name == "tab-compare")
	| .content.items[]
	| select(.type == 3)
	| .name + "\t" + (.content.query | gsub("[[:space:]]+"; " "))
' "$WB_JSON" > "$cmp_panels" 2>/dev/null || true
cmp_seen=0
while IFS="$(printf '\t')" read -r pname pquery; do
	[ -n "$pname" ] || continue
	cmp_seen=$((cmp_seen + 1))
	# Which table does this panel read? Only token-cost reads customEvents.
	if printf '%s' "$pquery" | grep -Fq 'customEvents'; then
		token='{CmpEvtBase}'
		tbl='customEvents'
	else
		token='{CmpDepBase}'
		tbl='dependencies'
	fi
	refs=0
	inlines=0
	if printf '%s' "$pquery" | grep -Fq "$token"; then refs=1; fi
	if printf '%s' "$pquery" | grep -Fq "$HV_EXTEND"; then inlines=1; fi
	if [ "$refs" -ne 1 ] || [ "$inlines" -ne 0 ]; then
		note "$WB_JSON: tab-compare panel '$pname' ($tbl) must reference $token and drop the inlined '$HV_EXTEND' (refs=$refs inlines=$inlines) — #224 hoist"
		cmp_hoist_ok=0
	fi
done < "$cmp_panels"
if [ "$cmp_seen" -ne 8 ]; then
	note "$WB_JSON: expected 8 by-version panels under tab-compare, found $cmp_seen — #224 hoist scope changed"
	cmp_hoist_ok=0
fi

# (3) the hoisted fragment must not smuggle a non-allowlisted customDimensions
#     key. Harvest keys from the two fragment values exactly as the B leg does,
#     then judge with the same is_shippable_key helper.
cmp_frag_file="$extract_dir/compare-fragments.txt"
{ printf '%s\n' "$cmp_dep_frag"; printf '%s\n' "$cmp_evt_frag"; } > "$cmp_frag_file"
cmp_frag_keys="$extract_dir/compare-fragment-keys.txt"
{
	grep -Eo "customDimensions\[['\"][^'\"]+['\"]\]" "$cmp_frag_file" \
		| grep -Eo "['\"][^'\"]+['\"]" | tr -d "\"'"
	grep -Eo 'customDimensions\.[A-Za-z0-9_.]+' "$cmp_frag_file" | sed 's/^customDimensions\.//'
	grep -Eo '(gen_ai|harness)\.[A-Za-z0-9_.]+' "$cmp_frag_file"
} 2>/dev/null | sort -u > "$cmp_frag_keys" || true
if [ -n "$ALLOWLIST_JSON" ]; then
	while IFS= read -r k; do
		[ -n "$k" ] || continue
		case "$k" in
		measurements* | gen_ai.usage.*) continue ;;
		esac
		if ! is_shippable_key "$k"; then
			note "$WB_JSON: hoisted compare fragment references key '$k' which is NOT allowlist-shippable — hoisting must not smuggle a dropped key (#224)"
			cmp_hoist_ok=0
		fi
	done < "$cmp_frag_keys"
fi

if [ "$cmp_hoist_ok" -eq 1 ]; then
	ok "#224: tab-compare shared 'extend hv' hoisted into CmpDepBase/CmpEvtBase fragments; all 8 panels reference their token, none inline the extend, and the fragments are allowlist-clean"
fi

# =============================================================================
# #224 — version-multiselect-param. compare-base-query-hoist put the shared
# `extend hv = tostring(customDimensions['harness.version'])` into the
# CmpDepBase/CmpEvtBase fragments that all 8 by-version compare panels inherit.
# This next feature makes the by-version comparison user-drivable: a Version
# multi-select parameter, populated FROM the data, whose 'All' selection is a
# provable no-op (parity with the unfiltered pack). The contract:
#   (1) a workbook parameter named Version exists with "multiSelect": true, a
#       populating "query" that reads customDimensions['harness.version'] (the
#       version list comes from the data, never hardcoded), AND an include-all
#       wildcard sentinel — "includeAll": true PLUS a literal "*" all-value
#       (accept "allValue":"*" OR "selectAllValue":"*", but the "*" literal
#       MUST be present in the Version param);
#   (2) BOTH the CmpDepBase AND CmpEvtBase fragments carry all THREE no-op
#       markers so an 'All' selection cannot drop rows:
#         '{Version}'         (the token is substituted in),
#         hv in ({Version})   (the filter binds the hoisted hv column), and
#         == '*'              (the wildcard short-circuit:
#                              where '{Version}' == '*' or hv in ({Version}))
#       Both fragments must inherit the filter so all 8 panels get it. The
#       == '*' no-op marker is load-bearing: a filter WITHOUT it would drop
#       every row on an 'All' selection (the parity bug) — a bare
#       `where hv in ({Version})` is NOT sufficient.
# Scoped strictly to the Version param + the two compare fragments; no other
# tab can false-satisfy it.
# =============================================================================
ver_ok=1
ver_param="$(jq -c '[.. | objects | select(.name? == "Version")] | .[0] // {}' "$WB_JSON" 2>/dev/null || echo '{}')"

# (1a) multiSelect true + includeAll true.
if ! printf '%s' "$ver_param" | jq -e '.multiSelect == true' >/dev/null 2>&1; then
	note "$WB_JSON: no Version parameter with \"multiSelect\": true — the by-version compare tab needs a data-populated multi-select Version filter (#224 version-multiselect-param)"
	ver_ok=0
fi
if ! printf '%s' "$ver_param" | jq -e '.includeAll == true' >/dev/null 2>&1; then
	note "$WB_JSON: Version parameter is missing \"includeAll\": true — an 'All' choice must exist so the default selection charts the whole pack (#224)"
	ver_ok=0
fi

# (1b) the populating query reads the version dimension FROM the data.
ver_query="$(printf '%s' "$ver_param" | jq -r '.query // ""' 2>/dev/null || echo "")"
if ! printf '%s' "$ver_query" | grep -Fq "customDimensions['harness.version']"; then
	note "$WB_JSON: Version parameter has no populating query over customDimensions['harness.version'] — the version list must come from the data, not a hardcoded set (#224)"
	ver_ok=0
fi

# (1c) the include-all wildcard sentinel: a literal "*" all-value. Accept the
#      field the impl uses (allValue OR selectAllValue) but REQUIRE the "*".
if ! printf '%s' "$ver_param" | jq -e '(.allValue == "*") or (.selectAllValue == "*")' >/dev/null 2>&1; then
	note "$WB_JSON: Version parameter has no wildcard all-value sentinel (\"allValue\":\"*\" or \"selectAllValue\":\"*\") — the 'All' selection must resolve to the literal * that the fragment no-op tests (#224)"
	ver_ok=0
fi

# (2) BOTH compare fragments must carry ALL THREE no-op markers so 'All' is a
#     provable no-op (parity with the unfiltered pack). Re-read them fresh so
#     this leg does not depend on the hoist leg's locals.
ver_dep_frag="$(jq -r '[.. | objects | select(.name? == "CmpDepBase") | .value | if type == "string" then . else tojson end] | .[0] // ""' "$WB_JSON" 2>/dev/null || echo "")"
ver_evt_frag="$(jq -r '[.. | objects | select(.name? == "CmpEvtBase") | .value | if type == "string" then . else tojson end] | .[0] // ""' "$WB_JSON" 2>/dev/null || echo "")"
for pair in "CmpDepBase:$ver_dep_frag" "CmpEvtBase:$ver_evt_frag"; do
	fname="${pair%%:*}"
	fval="${pair#*:}"
	has_token=0
	has_in=0
	has_star=0
	if printf '%s' "$fval" | grep -Fq "'{Version}'"; then has_token=1; fi
	if printf '%s' "$fval" | grep -Fq 'hv in ({Version})'; then has_in=1; fi
	if printf '%s' "$fval" | grep -Fq "== '*'"; then has_star=1; fi
	if { [ "$has_token" -eq 1 ] && [ "$has_in" -eq 1 ] && [ "$has_star" -eq 1 ]; }; then
		:
	else
		note "$WB_JSON: $fname fragment is missing a Version no-op marker (token '{Version}':$has_token filter hv in ({Version}):$has_in wildcard == '*':$has_star) — every compare panel must inherit \"where '{Version}' == '*' or hv in ({Version})\" so an 'All' selection drops no rows (#224 parity)"
		ver_ok=0
	fi
done

if [ "$ver_ok" -eq 1 ]; then
	ok "#224: Version multi-select parameter (data-populated, includeAll + * wildcard) exists and BOTH CmpDepBase/CmpEvtBase fragments carry the '{Version}' / hv in ({Version}) / == '*' no-op filter so 'All' is a provable no-op across all 8 panels"
fi

# =============================================================================
# #224 — deferred-metrics-verbatim-guard. The compare tab's `deferred-metrics`
# text block is a load-bearing honesty artifact: it names the contract-deferred
# metrics (review-blocking findings, per-feature attribution) as explicitly
# UNAVAILABLE and pins the honest red_reentry_free_rate / token-cost / #163
# narrative. The F1/F2 hoist/refactor must retain that block byte-for-byte. This
# guard jq-extracts ONLY the tab-compare `deferred-metrics` item content (by tab
# name AND item name, so no other tab/text item can false-satisfy) and
# SET-asserts the exact pinned sentence fingerprint verbatim: if ANY of the
# distinctive strings drifts by even one word, the leg goes RED.
# =============================================================================
dm_json="$(jq -r '
	.items[] | select(.name=="tab-compare")
	| .content.items[] | select(.name=="deferred-metrics")
	| .content.json // ""
' "$WB_JSON" 2>/dev/null || echo "")"
if [ -z "$dm_json" ]; then
	note "#224: could not jq-extract the tab-compare 'deferred-metrics' text item (.items[]|select(name==\"tab-compare\").content.items[]|select(name==\"deferred-metrics\").content.json) — the verbatim honesty block is missing or moved (deferred-metrics-verbatim-guard)"
else
	dm_missing=""
	# Each string is a distinctive verbatim fingerprint of the pinned block;
	# together they pin heading, both deferred-metric bullets, the honest
	# red_reentry_free_rate sentence, and the #163 token-gap pointer.
	while IFS= read -r pin; do
		[ -n "$pin" ] || continue
		if ! printf '%s' "$dm_json" | grep -Fq "$pin"; then
			dm_missing="$dm_missing
    - $pin"
		fi
	done <<'DM_PINS'
## Deferred metrics - explicitly UNAVAILABLE
The following contract-deferred metrics are NOT charted because trace-summary.v1.json does not carry them.
Review-blocking findings per issue: DEFERRED / unavailable / n/a
Per-feature attribution of tool calls: DEFERRED / unavailable / n/a
The red_reentry_free_rate panel above measures no-red-after-green re-entry
tracked in #163
DM_PINS
	if [ -n "$dm_missing" ]; then
		note "#224: the tab-compare 'deferred-metrics' block drifted from its pinned verbatim text — the F1/F2 refactor must retain it byte-for-byte. Missing verbatim string(s):$dm_missing"
	else
		ok "#224: tab-compare 'deferred-metrics' honesty block retained verbatim (heading, both DEFERRED bullets, honest red_reentry_free_rate sentence, and #163 token-gap pointer all pinned) — deferred-metrics-verbatim-guard"
	fi
fi

# =============================================================================
# #224 — compare-map-readme-update. The Version-comparison tab gains two live
# behaviours in this issue: (1) a multi-select {Version} filter whose 'All'
# selection is an honest no-op (reproducing the pre-change by-harness.version
# aggregates), and (2) a per-table base-query hoist (CmpDepBase / CmpEvtBase)
# that factors the shared `extend hv` prelude into ONE base query per App
# Insights table (dependencies / customEvents). The dashboards README must
# DOCUMENT both, not just the workbook JSON. This leg extracts ONLY the
# "Version comparison" tab bullet passage (from the `- **Version comparison**`
# line to the next blank line) so nothing outside the compare-tab narrative can
# false-satisfy, then SET-asserts the distinctive verbatim tokens the two
# additions introduce. The current README says only "the original
# by-`harness.version` aggregates and the deferred-metrics block, kept verbatim"
# — so every token below is absent and the leg is RED until the compare-tab
# narrative documents the {Version} multi-select no-op filter AND the
# CmpDepBase/CmpEvtBase hoist.
# =============================================================================
cmp_readme_section="$extract_dir/readme-compare-tab.section"
if [ -f "$DASH_README" ]; then
	awk '
		/^- \*\*Version comparison\*\*/ { grab = 1; print; next }
		grab && /^$/ { grab = 0; next }
		grab { print }
	' "$DASH_README" > "$cmp_readme_section" 2>/dev/null || true
else
	: > "$cmp_readme_section"
fi
if [ ! -s "$cmp_readme_section" ]; then
	note "#224: could not extract the 'Version comparison' tab bullet from $DASH_README (expected a '- **Version comparison**' bullet in the Workbook structure list) — compare-map-readme-update"
else
	# SET of distinctive verbatim tokens the two #224 additions introduce.
	# (1) {Version} multi-select + honest 'All'/no-op parity; (2) the
	# CmpDepBase/CmpEvtBase hoist of the shared `extend hv` prelude into one
	# base query per table (dependencies/customEvents).
	cmp_rm_missing=""
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		if ! grep -Fq "$tok" "$cmp_readme_section"; then
			cmp_rm_missing="$cmp_rm_missing
    - $tok"
		fi
	done <<'CMP_RM_TOKENS'
{Version}
multi-select
no-op
'All'
CmpDepBase
CmpEvtBase
extend hv
dependencies
customEvents
base query
CMP_RM_TOKENS
	if [ -n "$cmp_rm_missing" ]; then
		note "#224: the README 'Version comparison' tab narrative does not document the new compare-tab features — it must name the multi-select {Version} filter with its honest 'All'/no-op parity AND the per-table base-query hoist (CmpDepBase/CmpEvtBase factoring the shared 'extend hv' prelude into one base query per table: dependencies/customEvents). Missing token(s):$cmp_rm_missing"
	else
		ok "#224: README 'Version comparison' tab narrative documents the multi-select {Version} no-op filter and the CmpDepBase/CmpEvtBase base-query hoist (extend hv factored per dependencies/customEvents table) — compare-map-readme-update"
	fi
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
