# Harness Quality Workbook (issue #113). A live-deployed Azure Workbook that
# charts cross-run quality keyed on customDimensions['harness.version'],
# reading the module's OWN Application Insights component. The serialized
# Workbook JSON lives in harness-quality.workbook.json so its embedded KQL is
# statically lintable (allowlist / table / timespan). Azure requires the
# workbook `name` to be a GUID; that is the one legitimate literal here — every
# other id (the App Insights it targets, the resource group, the location) is a
# Terraform reference, never a committed literal.

resource "azurerm_application_insights_workbook" "harness_quality" {
  name                = "23b8d3e4-281f-4bb6-bfe7-4d429602f1f3"
  resource_group_name = azurerm_resource_group.telemetry.name
  location            = azurerm_resource_group.telemetry.location

  display_name = "Harness Quality Workbook"
  category     = "workbook"

  source_id = lower(azurerm_application_insights.telemetry.id)
  data_json = file("harness-quality.workbook.json")

  tags = var.tags
}
