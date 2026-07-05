# Outputs consumed by other layers. The connection string is what the OTLP
# exporter (#112) uses; both credentials are sensitive and must only ever be
# read into environment variables, never committed.

output "connection_string" {
  description = "Application Insights connection string (feed to APPLICATIONINSIGHTS_CONNECTION_STRING via env only)."
  value       = azurerm_application_insights.telemetry.connection_string
  sensitive   = true
}

output "instrumentation_key" {
  description = "Application Insights instrumentation key (legacy ingestion path; prefer the connection string)."
  value       = azurerm_application_insights.telemetry.instrumentation_key
  sensitive   = true
}

output "workspace_id" {
  description = "Resource ID of the Log Analytics workspace (for #113 retention/dashboard work)."
  value       = azurerm_log_analytics_workspace.telemetry.id
}

output "app_insights_id" {
  description = "Resource ID of the Application Insights component."
  value       = azurerm_application_insights.telemetry.id
}
