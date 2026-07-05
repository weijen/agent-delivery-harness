# Telemetry sink (Application Insights) — issue #115

Minimal Terraform stack that provisions the telemetry sink for the harness:

- one resource group
- one Log Analytics workspace (`retention_in_days`, `daily_quota_gb`)
- one workspace-based Application Insights component (`sampling_percentage`,
  `daily_data_cap_in_gb`)

A single `daily_cap_gb` variable drives both the workspace quota and the App
Insights cap so the two knobs can never diverge. Retention, cap, and sampling
values are governed by the retention/dashboard spec (#113). Deliberate
non-goals: no dashboards, alerts, action groups, or any other Azure footprint.

## Remote state (documented, never committed)

Production-shaped deployments must use the **azurerm backend** (Azure Storage
Account + container, with state locking). Treat state as sensitive — it can
contain secrets — and restrict access to the state container.

No backend block is committed in this repo: backend settings identify a real
subscription/storage account and are wired **per deployment** via
`-backend-config` flags (or a local, untracked `*.backend.hcl` file):

```sh
terraform init \
  -backend-config="resource_group_name=<state-rg>" \
  -backend-config="storage_account_name=<state-sa>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=telemetry-sink.tfstate"
```

Backend settings, state files, and real `*.tfvars` are never committed
(`.gitignore` enforces this; `terraform.tfvars.example` is the non-secret
template). Without a backend config, state stays local — fine for throwaway
dev spikes only.

## Workflow

Authenticate with `az login` (locally) or a Managed Identity / Service
Principal via `ARM_*` environment variables (CI). Credentials never live in
provider blocks or tfvars.

```sh
az login                          # or ARM_* env in controlled environments
cd infra/terraform
terraform init                    # add -backend-config flags for remote state
terraform fmt -recursive          # format before every commit
terraform validate
terraform plan -out=tfplan        # ALWAYS read the plan before applying
terraform apply tfplan
```

## Consuming the sink (#112 OTLP exporter)

The exporter reads the connection string from the environment only — it is
sensitive, marked `sensitive = true` in `outputs.tf`, and never committed to
any config file:

```sh
export APPLICATIONINSIGHTS_CONNECTION_STRING="$(terraform output -raw connection_string)"
```

## Security boundary

Telemetry must stay within the evaluation data boundary: see
[docs/evaluation/dataset-governance.md](../../docs/evaluation/dataset-governance.md)
and [docs/evaluation/security-evals.md](../../docs/evaluation/security-evals.md)
for what may and may not be exported as trace/telemetry content.

## Notes

- Provider pins: `versions.tf` (terraform `>= 1.9`, azurerm `~> 4.0`) plus the
  committed `.terraform.lock.hcl` for reproducible provider resolution.
- `prevent_destroy` is intentionally not set while this is a POC sink; add a
  lifecycle guard if the workspace ever becomes a load-bearing data store.
