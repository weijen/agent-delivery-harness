# Provider configuration for the telemetry-sink stack.
# No credential arguments here — authentication comes from the environment
# (az login locally, Managed Identity / Service Principal via ARM_* in
# controlled deployment environments). Remote state (azurerm backend with
# locking) is documented, never committed.
provider "azurerm" {
  features {}
}
