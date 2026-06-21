---
description: 'Terraform & Azure best practices for provisioning project infrastructure.'
applyTo: '**/*.tf'
---

# Terraform & Azure Best Practices

We use **Terraform** to provision **Azure** resources such as Azure AI Foundry projects, storage,
RBAC role assignments, Function Apps, Container Apps, and other project infrastructure.

## Layout & structure
- Keep infrastructure under `infra/terraform/` (or `infra/<stack>/` if more than one stack).
- Split by concern: `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf`.
- Group reusable infrastructure into **modules** (`modules/<name>/`). Don't repeat resource
  blocks across environments — parameterize a module instead.
- Separate environments (dev/stage/prod) via workspaces or per-env `*.tfvars` + backend keys.
  For a 1-week POC, a single `dev` env is usually enough.

## Provider & version pinning
- Pin Terraform and provider versions in `versions.tf`:
  ```hcl
  terraform {
    required_version = ">= 1.9"
    required_providers {
      azurerm = {
        source  = "hashicorp/azurerm"
        version = "~> 4.0"
      }
      azapi = {
        source  = "Azure/azapi"
        version = "~> 2.0"
      }
    }
  }
  ```
- Always set `features {}` on the `azurerm` provider.
- Use `azapi` for Foundry / Content Understanding resources that the `azurerm` provider does
  not yet cover natively.

## State
- **Never** commit local state. Use a **remote backend** (Azure Storage Account + container)
  with state locking. Configure via `backend "azurerm"`.
- Treat state as sensitive — it can contain secrets. Restrict access to the state container.

## Naming & tagging
- Use a consistent naming convention: `<project-prefix>-<env>-<resource>` (for example,
  `<prefix>-dev-rg`). Keep the project prefix short enough to fit Azure name limits.
- Apply common **tags** to every resource (`environment`, `project`, `managed_by = "terraform"`,
  `owner`, `cost-center`). Define them once as a local and merge into each resource.

## Variables & secrets
- Declare every input in `variables.tf` with `type`, `description`, and sensible `default`s
  where appropriate. Mark secrets `sensitive = true`.
- Never hard-code secrets, subscription IDs, or connection strings. Source them from
  **Azure Key Vault**, environment variables (`ARM_*`), or a secrets manager — not `.tfvars`
  committed to git.
- Authenticate via Azure CLI (`az login`) locally or a **Managed Identity / Service Principal**
  in a controlled deployment environment. Don't put credentials in provider blocks.

## Resource hygiene
- Prefer specific resource arguments over `null_resource`/local-exec workarounds.
- Use `for_each` over `count` when managing collections (stable addressing on change).
- Add `lifecycle` rules (`prevent_destroy`) on stateful/critical resources (storage accounts,
  Key Vaults, databases, or other protected data stores).
- Define `outputs.tf` for values other layers/teams consume (Foundry endpoint, deployment
  names, blob container URL).

## Workflow & quality gates
```sh
terraform fmt -recursive     # format
terraform validate           # validate config
terraform plan -out=tfplan   # review the plan — ALWAYS read it before applying
terraform apply tfplan       # apply the reviewed plan
```
- Run `terraform fmt` and `terraform validate` before every commit.
- **Always review `plan` output** before `apply`. Never `apply -auto-approve` against
  shared/prod environments.
- Run `tflint` and a security scanner (`checkov` / `tfsec`) before applying shared or
  production infrastructure changes.

## Safety
- `terraform destroy` is destructive — confirm scope and never run it against prod without
  explicit approval.
- Use `-target` only for surgical fixes, not as routine workflow.
- Customer or protected data stored in Azure is sensitive — never run `destroy` on a storage
  account or data store without confirming the data has been retained, purged, or returned per
  the applicable data agreement.
