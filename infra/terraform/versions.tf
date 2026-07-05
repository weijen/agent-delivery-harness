# Version pins for the telemetry-sink stack (issue #115).
# Provider pins are locked further by the committed .terraform.lock.hcl.
terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
