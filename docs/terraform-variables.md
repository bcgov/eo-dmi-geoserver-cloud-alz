# Terraform Variable Reference

The source of truth for variable names and type validation is
[infra/stack/variables.tf](../infra/stack/variables.tf). This document groups
the variables by operation and describes the coordination points.

## Required Core Variables

These values do not have a useful default and must be supplied through
`TF_VAR_*`, `terraform.tfvars`, or the workflow environment:

- `environment`
- `resource_group_name`
- `vnet_name`
- `vnet_resource_group_name`
- `aca_subnet_cidr`
- `private_endpoints_subnet_name`
- `acr_name`
- `key_vault_name`
- `postgres_server_name`
- `gs_cloud_version`
- `proxy_app_service_name`
- `oidc_client_id`

`environment` accepts `dev`, `test`, `prod`, and `tools`.

## General and Naming

| Variable | Default | Notes |
| --- | --- | --- |
| `project` | `geoserver` | Resource name prefix. |
| `location` | `canadacentral` | Azure region. |
| `ministry_name` | `WLRS` | Mandatory ALZ tag value. |
| `extra_tags` | `{}` | Additional tags. |
| `log_analytics_name` | Derived | Defaults to `log-<project>-<environment>`. |
| `container_app_environment_name` | Derived | Defaults to `cae-<project>-<environment>`. |
| `uami_name` | Derived | Defaults to `id-<project>-<environment>`. |

Globally unique values are normally required for ACR, Key Vault, PostgreSQL,
App Service, and storage account names.

## Network and Key Vault

| Variable | Default | Notes |
| --- | --- | --- |
| `aca_subnet_cidr` | Required | Must be free, valid CIDR and at least `/27`. |
| `app_service_subnet_cidr` | `10.46.10.144/28` | Must be free and at least `/28`. |
| `private_endpoints_subnet_name` | Required | Existing platform subnet. |
| `key_vault_public_network_access_enabled` | `false` | Use public access only for approved bootstrap conditions. |
| `key_vault_network_default_action` | `Deny` | Valid values: `Allow`, `Deny`. |
| `scripts_dir` | Empty | Directory containing DNS wait scripts. |
| `private_endpoint_dns_wait` | `12m` / `30s` | Timeout and polling interval. |

Do not modify the platform networking resource group directly.

## Runtime Sizing

| Variable | Default | Impact |
| --- | --- | --- |
| `zone_redundancy_enabled` | `false` | Availability and cost of the ACA environment. |
| `postgres_version` | `18` | PostgreSQL major version. |
| `postgres_sku_name` | `GP_Standard_D2ds_v5` | Database capacity and cost. |
| `postgres_enable_high_availability` | `false` | Production availability and cost. |
| `service_cpu` | `1.0` | Default service CPU. |
| `service_memory` | `2Gi` | Default service memory. |
| `service_min_replicas` | `0` | Scale-to-zero risk for services not overridden in `locals.tf`. |
| `service_max_replicas` | `2` | Replica ceiling. |

The service map in `infra/stack/locals.tf` overrides these defaults for the
core GeoServer services. Check both files before changing scale or resources.

## Application Versions

| Variable | Default | Notes |
| --- | --- | --- |
| `gs_cloud_version` | Required | GeoServer Cloud image tag. |
| `acl_version` | `3.0.1` | ACL image tag. |
| `rabbitmq_image_tag` | `4.0.9-management-alpine` | RabbitMQ image tag. |
| `rabbitmq_user` | `geoserver` | RabbitMQ application user. |
| `spring_profiles_active` | `standalone,pgconfig,acl,environment-admin-auth` | Shared GeoServer profiles. |
| `extra_service_env` | `{}` | Additional environment values for all services. |
| `reset_pgconfig_schema` | `false` | Destructive catalog reset for planned major migrations only. |

`reset_pgconfig_schema=true` drops the `pgconfig` schema and the GeoServer
catalog. Back up and approve the operation before using it.

## Proxy and Identity

| Variable | Default | Notes |
| --- | --- | --- |
| `proxy_sku` | `B2` | App Service plan size. |
| `proxy_image_tag` | `latest` | Use an immutable operational tag for production. |
| `oidc_issuer` | BC Gov test realm | Change per approved identity environment. |
| `oidc_client_id` | Required | Keycloak client ID. |
| `admin_idir_principal` | Project default | Lower-case email bootstrapped as GeoServer administrator. |
| `machine_client_usernames` | `svc-machine-wildlife` | One authkey identity per machine client. |

Proxy secrets are read from Key Vault by App Service. See
[security-and-identity.md](security-and-identity.md).

## Coordination Rules

- The `environment` value must match the catalog environment file.
- `gs_cloud_version`, `acl_version`, and `rabbitmq_image_tag` must exist in ACR
  after Terraform image import.
- `machine_client_usernames` must have matching Key Vault secrets and
  username-scoped ACL rules.
- `proxy_app_service_name` determines the OIDC redirect URI.
- `oidc_client_id` and `oidc_issuer` must match the registered Keycloak client.
- PostgreSQL and Key Vault names must match the per-environment secret references.

## State and Backend Variables

These are shell or GitHub Environment Variables used by `tf.sh`, not Terraform
input variables:

| Variable | Default |
| --- | --- |
| `TFSTATE_RESOURCE_GROUP` | `rg-geoserver-tfstate-<env>` |
| `TFSTATE_STORAGE_ACCOUNT` | `stgeoservertf<env>` |
| `TFSTATE_CONTAINER` | `tfstate` |
| `TFSTATE_KEY` | `geoserver-cloud/<env>.tfstate` |

Use one state key per environment.
