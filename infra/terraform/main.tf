# Telemetry-sink stack (issue #115): one resource group, one Log Analytics
# workspace, one workspace-based Application Insights component. Deliberately
# minimal — no dashboards, alerts, or monitor resources (issue non-goal).
# The single daily-cap knob (var.daily_cap_gb) is wired to BOTH the workspace
# quota and the App Insights cap so the two can never diverge (#113).

resource "azurerm_resource_group" "telemetry" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "telemetry" {
  name                = var.log_analytics_workspace_name
  location            = azurerm_resource_group.telemetry.location
  resource_group_name = azurerm_resource_group.telemetry.name

  sku               = "PerGB2018"
  retention_in_days = var.retention_in_days
  daily_quota_gb    = var.daily_cap_gb

  tags = var.tags
}

resource "azurerm_application_insights" "telemetry" {
  name                = var.application_insights_name
  location            = azurerm_resource_group.telemetry.location
  resource_group_name = azurerm_resource_group.telemetry.name

  workspace_id     = azurerm_log_analytics_workspace.telemetry.id
  application_type = "other"

  retention_in_days    = var.retention_in_days
  sampling_percentage  = var.sampling_percentage
  daily_data_cap_in_gb = var.daily_cap_gb

  tags = var.tags
}
