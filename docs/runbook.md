# Runbook — GeoServer Cloud on Azure Container Apps (BC Gov ALZ)

Operational guide for bootstrapping, deploying, and hardening the stack. Read
this alongside [`architecture.md`](architecture.md).

## 1. Prerequisites

- Terraform `>= 1.15`, Azure CLI (`az`), and (for local runs) `az login`.
- A BC Gov ALZ project set (the `<LicensePlate>-<env>-networking` resource group)
  with:
  - a spoke VNet,
  - a subnet **delegated to `Microsoft.App/environments`** (≥ `/27`) for the
    Container Apps environment,
  - a subnet for **private endpoints**.
- Owner of the `DO_PuC_Azure_Live_<LicensePlate>_Contributor` security group (the
  Product Owner by default) to run the bootstrap script, or have the PO add you.

## 2. One-time bootstrap — identity, OIDC, and state backend

Bootstrapping is handled by the **BC Gov platform script**, run **directly from
GitHub** (this repo no longer ships a local `bootstrap-backend.sh`):

<https://github.com/bcgov/ai-hub-tracking/blob/main/initial-setup/initial-azure-setup.sh>

```bash
curl -fsSLO https://raw.githubusercontent.com/bcgov/ai-hub-tracking/main/initial-setup/initial-azure-setup.sh
chmod +x initial-azure-setup.sh
./initial-azure-setup.sh \
  -g "<LicensePlate>-dev-networking" \   # networking resource group
  -n "geoserver-dev-identity" \          # user-assigned managed identity name
  -r "bcgov/eo-dmi-geo-server-cloud" \   # GitHub org/repo
  -e "dev" \                             # environment (dev|test|prod)
  -s "<subscription-id>" \               # optional: pin the subscription
  --create-storage \                     # create the Terraform state storage account
  --create-github-secrets                # create the GitHub environment + variables
```

What it creates:

- a **user-assigned managed identity** for GitHub Actions,
- an **OIDC federated credential** scoped to `repo:<org>/<repo>:environment:<env>`
  (no client secrets),
- an **Azure storage account** for Terraform state (`--create-storage`),
- the **GitHub environment + `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
  `AZURE_SUBSCRIPTION_ID` Variables** (`--create-github-secrets`),
- membership of the managed identity in the project security group (or prints the
  manual step if you are not a group owner).

Run it **once per environment** (`dev`, `test`, `prod`).

> If you are not an owner of the security group, a project lead must add the new
> managed identity to `DO_PuC_Azure_Live_<LicensePlate>_Contributor` before the
> GitHub Actions deploys will work. See the script header and the BC Gov
> [user-management docs](https://developer.gov.bc.ca/docs/default/component/public-cloud-techdocs/azure/design-build-deploy/user-management/).

### Wiring the state backend into `tf.sh`

`infra/scripts/tf.sh` injects the backend config at `init` time from `TFSTATE_*`
variables (falling back to a default convention). Point them at the storage
account the bootstrap script created — locally via `export`, or in CI as repo /
environment GitHub Variables:

| Variable | Purpose | Default if unset |
| --- | --- | --- |
| `TFSTATE_RESOURCE_GROUP` | RG holding the state storage account | `rg-geoserver-tfstate-<env>` |
| `TFSTATE_STORAGE_ACCOUNT` | state storage account name | `stgeoservertf<env>` |
| `TFSTATE_CONTAINER` | blob container | `tfstate` |
| `TFSTATE_KEY` | state blob key | `geoserver-cloud/<env>.tfstate` |

State auth is AzureAD/OIDC (`use_azuread_auth=true`) — no storage access keys.

## 3. Deploy

```bash
# Fill REPLACE_ME values in infra/stack/terraform.tfvars first.
./infra/scripts/tf.sh dev init
./infra/scripts/tf.sh dev plan
./infra/scripts/tf.sh dev apply
```

`apply` is a **single pass**:

1. Resource group, Log Analytics, and the **ACR** are created.
2. Terraform **imports the GeoServer Cloud images** into the ACR via the
   server-side `importImage` action (`infra/modules/registry`, `azapi`) — no Docker
   daemon, no `az acr import`.
3. Key Vault, PostgreSQL, RabbitMQ, ACL, and the OWS Container Apps come up. The
   app modules `depends_on` the registry module, so they never start before
   their images exist.

The image set and pinned tags live in `infra/stack/terraform.tfvars`
(`gs_cloud_version`, `acl_version`, `rabbitmq_image_tag`) and are expanded into
the import list in `infra/stack/locals.tf` (`registry_images`). To change a
version, edit the tfvars and re-apply — the import is idempotent (`mode=Force`).

### CI/CD

- **PRs** → `ci.yml` runs fmt / validate / tflint / checkov, then `plan` (dev).
- **Merge to `main`** → `cd-dev.yml` applies dev (gated by the `dev` GitHub
  Environment).
- **`test` / `prod`** → `cd-test.yml` / `cd-prod.yml`, `workflow_dispatch` only,
  gated by their GitHub Environments (configure required reviewers in repo
  settings).

## 4. Hardening checklist (move off bootstrap defaults)

The bootstrap defaults trade some hardening for a first apply from a
Microsoft-hosted CI runner. Tighten these for production:

- **Key Vault data plane:** set `key_vault_public_network_access_enabled = false`
  and `key_vault_network_default_action = "Deny"` once applies run from a
  VNet-attached runner (self-hosted or Bastion), so secret writes traverse the
  private endpoint. (Re-enable the matching Checkov checks in `.checkov.yaml`.)
- **GeoWebCache persistence:** `GEOWEBCACHE_CACHE_DIR` is `/tmp/geowebcache`
  (ephemeral per replica). Back it with an Azure Files mount if you need a shared
  / durable tile cache.
- **PostgreSQL:** enable `postgres_enable_high_availability` and a larger
  `postgres_sku_name` for prod.
- **Gateway routing / 3.0 env contract:** validate the gateway→OWS routes and the
  exact GeoServer Cloud 3.0 standalone env variables during R&D — these are the
  main application-level unknowns.

## 5. Teardown

```bash
./infra/scripts/tf.sh dev destroy
```

Stateful resources (Key Vault, PostgreSQL) use `prevent_destroy` and the
provider's `prevent_deletion_if_contains_resources` guard — destroy will block on
them by design. Remove the guards deliberately if a full teardown is intended.
