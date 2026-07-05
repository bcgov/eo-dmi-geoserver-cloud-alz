# GeoServer Cloud on Azure Container Apps — BC Gov Azure Landing Zone

Infrastructure-as-Code to deploy [GeoServer Cloud](https://geoserver.org/geoserver-cloud/)
(cloud-native, dockerized GeoServer microservices) onto **Azure Container Apps**
inside the **BC Gov Azure Landing Zone (ALZ)**.

- **Terraform** modules + a single shared stack with per-environment state &
  variables (`dev` / `test` / `prod`)
- **GitHub Actions** with **OIDC federated identity** (no client secrets)
- **One Bash wrapper** (`scripts/tf.sh`) that runs `terraform` identically from a
  local machine or a GitHub Actions runner
- **Terraform-native image sourcing** — GeoServer Cloud images are imported into
  ACR by `terraform apply` via the server-side `azapi` importImage API (no Docker
  daemon, no separate import step)
- **Node OIDC edge proxy** — a stateless, public-facing App Service that handles
  BC Gov Keycloak (PKCE) login and injects a trusted `sec-username` header before
  reverse-proxying to the internal GeoServer gateway
- **Catalog-as-code** — `geo-server-app-config/` reconciles YAML-described
  workspaces, stores, layers, layer groups, and ACL rules against the live
  GeoServer REST API
- **Spec-Driven Development** via [OpenSpec](https://github.com/Fission-AI/OpenSpec)
  — planning artifacts live in `openspec/`; slash commands `/opsx:propose`,
  `/opsx:apply`, `/opsx:archive` are wired to GitHub Copilot

> **Status: active development on `feat/sdd`.** The core topology is fully
> wired. A handful of resource-name values (account coding, platform
> subnet/DNS names, globally-unique resource names) must be filled in before
> a real deploy — every placeholder is marked `REPLACE_ME` or called out in
> [`docs/runbook.md`](docs/runbook.md).

## Architecture

```
  Internet
     │
     ▼
  App Service (node-oidc-proxy) ◄──── BC Gov Keycloak (OIDC / PKCE)
     │  VNet-integrated, injects sec-username header
     │
     ▼
  VNet (platform-provided, locked *-networking RG)
  ┌────────────────────────────────────────────────────────────────┐
  │  Container Apps Environment (internal LB, workload profiles)   │
  │                                                                │
  │  gateway ──► webui · wms · wfs · wcs · wps · rest · gwc        │
  │     │             (internal ingress only, .internal. FQDNs)    │
  │     └──────────────────────────────► acl (authorization)       │
  │                                                                │
  │  rabbitmq (AMQP 5672 — catalog-change event bus, min 1)        │
  │                                                                │
  └──────────┬─────────────────────────────┬───────────────────────┘
             │ private endpoint             │ private endpoint
       PostgreSQL Flexible Server       Key Vault (secrets)
       (pgconfig + geodata DBs +        (ACR creds, RabbitMQ pwd,
        PostGIS, port 5432)              ACL passwords, OIDC secret)
  Standard ACR (admin creds)
    ▲ images imported by Terraform (azapi importImage, no Docker daemon)
    ▲ node-oidc-proxy image built by ACR Tasks (az acr build)
```

### Key design decisions

| Decision | Detail |
|----------|--------|
| **Standalone mode** | `pgconfig` catalog backend + `standalone` Spring profile; no Consul / Spring Cloud Config Server needed |
| **Internal LB only** | ACA environment has no public IP; only `gateway` has `external = true` ingress (reachable over VNet / SOCKS5) |
| **RabbitMQ always warm** | `min_replicas = 1` — TCP ingress has no scale trigger; at 0, auto-delete queues are lost and catalog events stop |
| **ACL always warm** | `min_replicas = 1` — ACL sits on the authz path of every secured OWS request |
| **webui sticky sessions** | Wicket requires same-replica affinity; applied via `azapi_update_resource` PATCH (azurerm 4.x doesn't expose `stickySessions`) |
| **Secrets never in state** | `null_resource` + `local-exec` (`az keyvault secret set`) writes secret values; KV versionless URIs are wired into ACA secrets |
| **PostGIS init job** | Container App Job runs inside the VNet to reach the private Postgres endpoint; triggered by `terraform apply` |
| **Deployment config** | Spring YAML files in `deployment-config/` are published to an ACA Environment Storage share mounted at `/etc/gscloud/deployment-config/` |

## Folder Structure

```
eo-dmi-geo-server-cloud/
├── README.md
├── mise.toml                     # pinned tool versions: tf 1.15.7 · node 24 · python 3.14
├── .gitignore  .editorconfig  .tflint.hcl  .checkov.yaml
├── .github/
│   ├── workflows/
│   │   ├── terraform-deploy.yml  # reusable: fmt→validate→tflint→checkov→plan→[apply]
│   │   ├── ci.yml                # PR → plan (tools env, no apply)
│   │   ├── cd-dev.yml            # push main / dispatch → apply dev
│   │   ├── cd-test.yml           # dispatch → apply test (gated)
│   │   └── cd-prod.yml           # dispatch → apply prod (gated)
│   ├── prompts/                  # OpenSpec /opsx:* slash commands for GitHub Copilot
│   ├── skills/                   # OpenSpec skill definitions
│   ├── dependabot.yml
│   └── copilot-instructions.md
├── scripts/
│   └── tf.sh                     # wrapper: ./scripts/tf.sh <env> <cmd>
├── modules/
│   ├── naming/                   # ALZ mandatory tags + name prefix
│   ├── network/                  # data sources over platform VNet/subnets; creates ACA + App Service subnets
│   ├── observability/            # Log Analytics workspace
│   ├── registry/                 # Standard ACR + server-side azapi importImage
│   ├── keyvault/                 # Key Vault + private endpoint + RBAC
│   ├── postgres/                 # PostgreSQL Flexible Server + private endpoint + DB init
│   ├── container-app-environment/# ACA environment (internal LB) + UAMI
│   ├── rabbitmq/                 # RabbitMQ event bus (Container App, durable Azure File share)
│   └── geoserver-service/        # reusable module for every GeoServer Cloud microservice
├── stack/                        # single shared Terraform stack for all environments
│   ├── main.tf                   # all resources: modules + null_resources for secrets/jobs
│   ├── locals.tf                 # services map, image list, shared env/secrets
│   ├── variables.tf              # all inputs (injected via TF_VAR_* in CI/CD)
│   ├── outputs.tf
│   ├── rabbitmq-storage.tf       # Azure Storage account + file share for RabbitMQ data
│   └── backend.tf / providers.tf / versions.tf / data.tf
├── deployment-config/            # Spring YAML files published to ACA storage
│   ├── gateway.yml / gateway-webflux.yml
│   ├── geoserver.yml / geoserver_spring.yml / geoserver_logging.yml
│   └── jndi.yml
├── node-oidc-proxy/              # public-facing OIDC edge proxy (TypeScript, Node 24)
│   ├── src/                      # config · logger · jwe · session · oidc · proxy · app · server
│   ├── Dockerfile                # multi-stage, non-root, HEALTHCHECK
│   └── package.json
├── geo-server-app-config/        # catalog-as-code: YAML → GeoServer REST API
│   ├── geoserver_apply.py        # Typer CLI (geoserver-apply run|validate)
│   ├── geoserver_catalog_schema.py # Pydantic v2 CatalogBundle schema
│   ├── reconcile.py              # load_catalog + apply (idempotent reconcile loop)
│   ├── geoserver_client.py       # GeoServer + ACL REST client
│   ├── catalog/                  # workspaces · stores · layers · layer_groups · acl_rules · styles
│   ├── environments/             # per-env YAML (kv:// and tf:// references for secrets)
│   └── pyproject.toml
├── integration-tests/            # pytest suite: proxy · OWS · catalog · rendering · security
├── openspec/                     # OpenSpec spec-driven development artifacts
│   ├── config.yaml               # project context + per-artifact rules
│   ├── specs/                    # source-of-truth specs (accumulate on archive)
│   └── changes/                  # one folder per in-flight or completed change
└── docs/
    ├── architecture.md
    ├── runbook.md
    └── node-oidc-proxy-contract.md
```

All environments share a single `stack/` directory. Environment identity, resource
names, and Terraform backend config are injected at runtime via `TF_VAR_*` /
`TFSTATE_*` env vars set per GitHub Environment.

## Tool versions (from `mise.toml`)

| Tool | Version |
|------|---------|
| Terraform | 1.15.7 |
| Node.js | 24 |
| Python | 3.14 |
| TFLint | 0.63.1 |
| uv | 0.10.11 |
| Checkov | 3.3.2 (env var) |
| TFLint azurerm ruleset | 0.28.0 (env var) |

## Quick Start

Prerequisites: `mise` (installs all tools from `mise.toml`), Azure CLI (`az`),
and the platform prerequisites in [`docs/runbook.md`](docs/runbook.md) (spoke
VNet with a delegated ACA subnet + a private-endpoint subnet).

```bash
# 0. Install tools
mise install

# 1. Fill in stack/terraform.tfvars (REPLACE_ME values).

# 2. One-time: create the managed identity, GitHub OIDC federated credential,
#    and the Terraform state storage account using the BC Gov platform script:
curl -fsSLO https://raw.githubusercontent.com/bcgov/ai-hub-tracking/main/initial-setup/initial-azure-setup.sh
chmod +x initial-azure-setup.sh
./initial-azure-setup.sh \
  -g "<LicensePlate>-dev-networking" \
  -n "geoserver-dev-identity" \
  -r "bcgov/eo-dmi-geoserver-cloud-alz" \
  -e "dev" \
  --create-storage --create-github-secrets

# 3. Initialize, plan, apply.
./scripts/tf.sh dev init
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply

# 4. (Optional) Validate the GeoServer catalog offline
pip install -e geo-server-app-config/
geoserver-apply validate --catalog-dir geo-server-app-config/catalog
```

The same `tf.sh` runs in GitHub Actions. Workflows authenticate via OIDC
federated identity and read config from GitHub **Variables** set per Environment.

## GitHub Actions workflows

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `ci.yml` | PR → `main` | fork-gate, PR title lint (Conventional Commits), `terraform plan` against `tools` env |
| `cd-dev.yml` | push `main` or dispatch | `terraform apply` → `dev` |
| `cd-test.yml` | dispatch | `terraform apply` → `test` (gated) |
| `cd-prod.yml` | dispatch | `terraform apply` → `prod` (gated) |
| `terraform-deploy.yml` | called by above | fmt → validate → tflint → checkov → plan → [apply] |

## Catalog-as-code (`geo-server-app-config/`)

```bash
# Validate catalog YAML offline (no GeoServer connection needed)
geoserver-apply validate --catalog-dir geo-server-app-config/catalog

# Apply to a live environment (resolves kv:// and tf:// references)
geoserver-apply run dev
```

The catalog YAML files live under `geo-server-app-config/catalog/`:

| File | Resources |
|------|-----------|
| `workspaces.yaml` | GeoServer workspaces + namespace URIs |
| `stores.yaml` | PostGIS datastore connections |
| `layers.yaml` | Feature type / layer definitions |
| `layer_groups.yaml` | Layer group definitions |
| `acl_rules.yaml` | GeoServer ACL access rules |
| `styles/` | SLD style files |

Environment-specific config lives in `geo-server-app-config/environments/<env>.yaml`.
Secret values use `kv://vault-name/secret-name` or `tf://output-name` notation
and are resolved at runtime — never hardcoded.

## Node OIDC Edge Proxy (`node-oidc-proxy/`)

A stateless TypeScript / Express 5 / Node 24 public-facing proxy that:
- Runs the BC Gov Keycloak OIDC Authorization Code + PKCE flow
- Seals the session into a `JWE` cookie (no server-side session store)
- Injects `sec-username` into every proxied request; strips `sec-*` / `x-gsc-*`
  anti-spoofing headers from inbound traffic
- Deployed as an Azure App Service (VNet-integrated) built by `az acr build`
  during `terraform apply`

See [`node-oidc-proxy/README.md`](node-oidc-proxy/README.md) and
[`docs/node-oidc-proxy-contract.md`](docs/node-oidc-proxy-contract.md).

## BC Gov ALZ guardrails honored

- The `*-networking` resource group is **never modified** — VNet/subnets are
  consumed via data sources only.
- **No public IPs** — ACA environment uses an internal load balancer; the
  gateway is only reachable over the spoke VNet (SOCKS5 or App Service VNet
  integration).
- **Private endpoints + private DNS** for PostgreSQL and Key Vault.
- **Mandatory tags** on every resource (`account_coding`, `billing_group`,
  `ministry_name`, `environment`, `owner`) via `modules/naming`.
- **OIDC-only** auth for Terraform state and deployments; `prevent_destroy` on
  stateful resources.
- **Secrets never in Terraform state** — written to Key Vault via `az keyvault
  secret set` in `null_resource` local-exec provisioners.

## Spec-Driven Development (OpenSpec)

This project uses [OpenSpec](https://github.com/Fission-AI/OpenSpec) for
structured, AI-assisted planning. The `/opsx:*` slash commands are available in
GitHub Copilot chat.

```text
/opsx:explore          # investigate before committing to a change
/opsx:propose <name>   # draft proposal · specs · design · tasks
/opsx:apply            # implement the tasks
/opsx:archive          # merge delta specs into openspec/specs/ and file away
```

Source-of-truth specs: `openspec/specs/`  
In-flight changes: `openspec/changes/`  
Project config: `openspec/config.yaml`

See [`docs/runbook.md`](docs/runbook.md) for setup, deploy order, GeoServer
Cloud app wiring, and bootstrap-vs-hardened tradeoffs.
