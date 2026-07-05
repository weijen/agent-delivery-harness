# Inputs for the telemetry-sink stack (issue #115).
# Telemetry knobs (retention / daily cap / sampling) are governed by the
# retention & dashboard spec (#113); naming follows <prefix>-<env>-<resource>.

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group that hosts the telemetry sink."
  default     = "adh-dev-rg"
}

variable "location" {
  type        = string
  description = "Azure region for all telemetry-sink resources."
  default     = "westeurope"
}

variable "log_analytics_workspace_name" {
  type        = string
  description = "Name of the Log Analytics workspace backing Application Insights."
  default     = "adh-dev-law"
}

variable "application_insights_name" {
  type        = string
  description = "Name of the workspace-based Application Insights component."
  default     = "adh-dev-appi"
}

variable "retention_in_days" {
  type        = number
  description = "Telemetry retention in days, applied to the workspace and the Application Insights component."
  default     = 30
}

variable "daily_cap_gb" {
  type        = number
  description = "Single daily ingestion cap in GB, wired to both the workspace daily_quota_gb and the Application Insights daily_data_cap_in_gb."
  default     = 1
}

variable "sampling_percentage" {
  type        = number
  description = "Percentage of telemetry sampled into Application Insights (100 = keep everything)."
  default     = 100
}

variable "tags" {
  type        = map(string)
  description = "Common tags merged into every telemetry-sink resource."
  default = {
    environment = "dev"
    project     = "agent-delivery-harness"
    managed_by  = "terraform"
  }
}
