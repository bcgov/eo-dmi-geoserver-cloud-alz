# GeoServer Cloud on Azure Container Apps — BC Gov Azure Landing Zone

Infrastructure-as-Code to deploy [GeoServer Cloud](https://geoserver.org/geoserver-cloud/)
(cloud-native, dockerized GeoServer microservices) onto **Azure Container Apps**
inside the **BC Gov Azure Landing Zone (ALZ)**.

- **Terraform** modules + a single shared stack with per-environment state &
  variables (`dev` / `test` / `prod`)
- **GitHub Actions** with **OIDC federated identity** (no client secrets)
- **One Bash wrapper** (`scripts/tf.sh`) that runs `terraform` identically from a
  local machine or a GitHub Actions runner
- **Terraform-native image sourcing** — the GeoServer Cloud images are imported
  into ACR by `terraform apply` (no separate import step / Docker daemon)

> Status: **bootstrap scaffold.** It encodes the ALZ guardrails and the full
> GeoServer Cloud 3.0 topology with images pinned to `3.0.0`, but a handful of
> values (account coding, platform subnet/DNS names, globally-unique resource
> names) must be filled in before a real deploy — every one is
> marked `REPLACE_ME` or called out in [`docs/runbook.md`](docs/runbook.md). The
> gateway→service routing and exact 3.0 env contract are the main things to
> validate during R&D.

## Architecture (summary)

```
                 VNet (platform-provided, locked networking RG)
   ┌───────────────────────────────────────────────────────────────┐
   │  Container Apps environment (workload profiles, INTERNAL LB)    │
   │                                                                 │
   │   gateway* ──► web-ui, wms, wfs, wcs, wps, rest, gwc            │
   │      │             │   │                                        │
   │      │             │   └──► acl (authorization service)         │
   │      └─────────────┴──► rabbitmq (event bus, AMQP 5672)         │
   │                                                                 │
   └──────────┬───────────────────────────┬──────────────────────────┘
              │ private endpoint          │ private endpoint
        PostgreSQL Flexible Server     Key Vault (secrets)
        (pgconfig catalog + PostGIS)
   Standard ACR (admin creds) ──► holds the GeoServer Cloud images
        ▲ images imported by Terraform (modules/registry, azapi importImage)

   * only the gateway is exposed on the environment's INTERNAL load balancer;
     all other services are reachable service-to-service only. No public IPs.
```

This deploys **GeoServer Cloud 3.0.0** in **standalone mode**: the `pgconfig`
catalog backend + the `standalone` Spring profile, so no Consul or Spring Cloud
Config server is needed — Azure Container Apps provides the service networking
(the documented Kubernetes deployment path). RabbitMQ carries catalog-change
events between services, and the **GeoServer ACL** service provides authorization.

> 3.0's Eureka→Consul change applies to the config-server/discovery deployment
> mode; the standalone mode used here relies on the platform's own service
> discovery instead, so Consul is intentionally not deployed.

## Folder Structure

```
eo-dmi-geo-server-cloud/
├── README.md
├── .gitignore  .editorconfig  .tflint.hcl  .checkov.yaml
├── .github/
│   ├── workflows/
│   │   ├── terraform-deploy.yml   # reusable: fmt→validate→tflint→checkov→plan→[apply]
│   │   ├── ci.yml                 # PR → plan only
│   │   ├── cd-dev.yml             # push main / dispatch → apply dev
│   │   ├── cd-test.yml            # dispatch → apply test (gated)
│   │   └── cd-prod.yml            # dispatch → apply prod (gated)
│   ├── dependabot.yml
│   └── CODEOWNERS
├── scripts/
│   └── tf.sh                      # wrapper: ./scripts/tf.sh <env> <cmd> (self-contained)
├── modules/
│   ├── naming/                    # mandatory ALZ tags + name prefix
│   ├── network/                   # data sources over the platform VNet/subnets
│   ├── observability/             # Log Analytics workspace
│   ├── registry/                  # Standard ACR (admin creds) + TF image import
│   ├── keyvault/                  # Key Vault + private endpoint + RBAC
│   ├── postgres/                  # PostgreSQL Flexible Server + PostGIS + PE
│   ├── container-app-environment/ # ACA env (internal LB) + shared identity
│   ├── rabbitmq/                  # RabbitMQ event bus (Container App)
│   └── geoserver-service/         # one GeoServer Cloud microservice (reusable)
├── stack/                         # single shared stack — one copy of the config
├── geo-server-app-config/        # catalog reconciliation + app-config bundle
│   ├── backend.tf  providers.tf  versions.tf  data.tf
│   ├── main.tf  locals.tf  variables.tf  outputs.tf
│   └── terraform.tfvars           # per-env values; env identity injected via TF_VAR_*
└── docs/
    ├── architecture.md
    └── runbook.md
```

All environments share the single `stack/` directory; environment identity,
resource names, and backend state key are injected at runtime via `TF_VAR_*` /
`TFSTATE_*` env vars set per GitHub Environment (see `scripts/tf.sh`).

## Quick Start

Prerequisites: Terraform `>= 1.15`, Azure CLI (`az`), and the platform
prerequisites in [`docs/runbook.md`](docs/runbook.md) (spoke VNet with a
delegated ACA subnet + a private-endpoint subnet).

```bash
# 1. Fill in stack/terraform.tfvars (REPLACE_ME values).

# 2. One-time: create the managed identity, GitHub OIDC federated credential,
#    and the Terraform state storage account using the BC Gov platform script,
#    run DIRECTLY from GitHub (see docs/runbook.md for the full flag reference):
curl -fsSLO https://raw.githubusercontent.com/bcgov/ai-hub-tracking/main/initial-setup/initial-azure-setup.sh
chmod +x initial-azure-setup.sh
./initial-azure-setup.sh \
  -g "<LicensePlate>-dev-networking" \
  -n "geoserver-dev-identity" \
  -r "bcgov/eo-dmi-geo-server-cloud" \
  -e "dev" \
  --create-storage --create-github-secrets

# 3. Point tf.sh at the state storage account the script created (names are
#    configurable — see docs/runbook.md), e.g.:
export TFSTATE_RESOURCE_GROUP="<rg the script created>"
export TFSTATE_STORAGE_ACCOUNT="<storage account the script created>"

# 4. Initialize, review the plan, and apply. The apply imports the GeoServer
#    Cloud images into the new ACR and brings up the apps in a single pass.
./scripts/tf.sh dev init
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply
```

The same `tf.sh` runs inside GitHub Actions — see the workflows under
`.github/workflows/`. The workflows authenticate via the OIDC federated identity
and read `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` from
GitHub **Variables** (created by `--create-github-secrets`).

## BC Gov ALZ guardrails honored

- The `*-networking` resource group is **never modified** — VNet/subnets are
  consumed via data sources.
- **No public IPs** — the Container Apps environment uses an internal load
  balancer; only the gateway is exposed, over the VNet.
- **Private endpoints + private DNS** for PostgreSQL and Key Vault (DNS records
  via the platform policy, or explicit zone ids if you provide them).
- **Mandatory tags** on every resource (`account_coding`, `billing_group`,
  `ministry_name`, `environment`, `owner`).
- **OIDC-only** auth for state and deploys; `prevent_destroy` on stateful
  resources.

See [`docs/runbook.md`](docs/runbook.md) for setup, deploy order, GeoServer
Cloud app wiring, and the documented bootstrap-vs-hardened tradeoffs.
