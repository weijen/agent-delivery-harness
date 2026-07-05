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

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "retention_in_days must be between 30 and 730 days (Log Analytics workspace limits)."
  }
}

variable "daily_cap_gb" {
  type        = number
  description = "Single daily ingestion cap in GB, wired to both the workspace daily_quota_gb and the Application Insights daily_data_cap_in_gb."
  default     = 1

  validation {
    condition     = var.daily_cap_gb > 0
    error_message = "daily_cap_gb must be greater than 0: the workspace's -1 'unlimited' sentinel is rejected by Application Insights daily_data_cap_in_gb, so the shared knob bans it."
  }
}

variable "sampling_percentage" {
  type        = number
  description = "Percentage of telemetry sampled into Application Insights (100 = keep everything)."
  default     = 100

  validation {
    condition     = var.sampling_percentage >= 0 && var.sampling_percentage <= 100
    error_message = "sampling_percentage must be between 0 and 100."
  }
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
