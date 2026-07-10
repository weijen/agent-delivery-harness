# Decommissioned: Harness Quality Workbook (2026-07-10, issue #272)

The `azurerm_application_insights_workbook.harness_quality` resource (formerly
`workbook.tf` + `harness-quality.workbook.json`) was removed by issue #272's L4
deletion review: the cloud trace/log **export leg** (`trace-export.sh`,
`log-export.sh`, `trace-reconstruct.sh`, and the `scripts/trace_tools/` OTLP /
App Insights modules) had no in-loop gate or recurring human consumer, and the
workbook was its only reader. With the export leg deleted, nothing ships
harness spans to Application Insights, so the workbook monitored an empty
stream.

Kept (still governed by this module): the Log Analytics workspace, the
Application Insights component, and their `retention_in_days` — the sink infra
remains as the future exit ramp if an in-loop consumer ever reappears. The
trace schema (`docs/evaluation/trace-schema.v1.json`) and OTel-aligned
attribute names stay documented for the same reason.

To restore a dashboard, re-add an `azurerm_application_insights_workbook`
targeting `azurerm_application_insights.telemetry` with a serialized
`data_json` payload; git history holds the last shipped workbook JSON.
