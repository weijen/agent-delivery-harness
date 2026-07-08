---
description: 'Terraform & Azure best practices for provisioning project infrastructure.'
applyTo: '**/*.tf'
---

# Terraform & Azure Best Practices

We use **Terraform** to provision **Azure** resources (resource groups, storage, RBAC role
assignments, compute, and whatever AI/ML services the project needs — e.g. an Azure AI Foundry
project). Standard Terraform mechanics — file layout, version pinning, remote state, the
`fmt` → `validate` → `plan` → `apply` flow — follow ordinary practice; the rules below are the
ones specific to this project's provider policy and safety posture.

## Layout & provider policy
- Keep infrastructure under `infra/terraform/` (or `infra/<stack>/` for more than one stack), and
  group reusable resources into **modules** (`modules/<name>/`) rather than repeating blocks per
  environment. Separate environments via workspaces or per-env `*.tfvars` + backend keys.
- Pin Terraform and provider versions in `versions.tf`; always set `features {}` on `azurerm`.
- Use `azapi` for resources the `azurerm` provider does not yet cover natively.

## State & secrets
- **Never** commit local state — use a remote backend (Azure Storage account + container) with
  state locking, and treat state as sensitive: it can contain secrets, so restrict access.
- Never hard-code secrets, subscription IDs, or connection strings. Source them from a secrets
  manager (e.g. Azure Key Vault), environment variables (`ARM_*`), or `az login` / a Managed
  Identity — never from `.tfvars` committed to git. Mark secret variables `sensitive = true`.

## Resource hygiene
- Use `for_each` over `count` when managing collections (stable addressing on change).
- Add `lifecycle { prevent_destroy = true }` on stateful/critical data stores (storage accounts,
  Key Vaults, databases, or other protected data).
- Define `outputs.tf` for values other layers/teams consume (service endpoints, deployment/model
  names, storage URLs).

## Safety
- **Always review `plan` output** before `apply`. Never `apply -auto-approve` against shared or
  production environments.
- `terraform destroy` is destructive — confirm scope, use `-target` only for surgical fixes, and
  never run it against prod without explicit approval.
- Customer or protected data stored in Azure is sensitive — never run `destroy` on a storage
  account or data store without confirming the data has been retained, purged, or returned per
  the applicable data agreement.
