# ---------------------------------------------------------------------------
# GeoServer Cloud on Azure Container Apps
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = module.naming.common_tags
}

module "naming" {
  source        = "../modules/naming"
  project       = var.project
  environment   = var.environment
  ministry_name = var.ministry_name
  extra_tags    = var.extra_tags
}

module "network" {
  source                        = "../modules/network"
  vnet_name                     = var.vnet_name
  vnet_resource_group_name      = var.vnet_resource_group_name
  private_endpoints_subnet_name = var.private_endpoints_subnet_name
  aca_subnet_cidr               = var.aca_subnet_cidr
  app_service_subnet_cidr       = var.app_service_subnet_cidr
  location                      = var.location
  name_prefix                   = module.naming.name_prefix
  common_tags                   = module.naming.common_tags

  depends_on = [module.naming]
}

module "observability" {
  source              = "../modules/observability"
  name                = local.log_analytics_name
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = module.naming.common_tags
}

module "registry" {
  source                     = "../modules/registry"
  name                       = var.acr_name
  resource_group_name        = azurerm_resource_group.this.name
  location                   = var.location
  sku                        = "Standard"
  admin_enabled              = true
  log_analytics_workspace_id = local.log_analytics_resource_id
  images                     = local.registry_images
  tags                       = module.naming.common_tags
}

module "container_app_environment" {
  source                              = "../modules/container-app-environment"
  name                                = local.container_app_environment_name
  resource_group_name                 = azurerm_resource_group.this.name
  location                            = var.location
  log_analytics_workspace_customer_id = module.observability.workspace_id
  log_analytics_workspace_key         = module.observability.log_analytics_workspace_key
  log_analytics_workspace_id          = module.observability.log_analytics_id
  infrastructure_subnet_id            = module.network.aca_subnet_id
  internal_load_balancer_enabled      = true
  zone_redundancy_enabled             = var.zone_redundancy_enabled
  enable_diagnostics                  = true
  uami_name                           = local.uami_name
  private_endpoints_subnet_id         = module.network.private_endpoints_subnet_id
  tags                                = module.naming.common_tags

}

module "keyvault" {
  source                        = "../modules/keyvault"
  name                          = var.key_vault_name
  resource_group_name           = azurerm_resource_group.this.name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  private_endpoints_subnet_id   = module.network.private_endpoints_subnet_id
  reader_principal_ids          = [module.container_app_environment.uami_principal_id]
  admin_principal_ids           = [data.azurerm_client_config.current.object_id]
  public_network_access_enabled = var.key_vault_public_network_access_enabled
  network_default_action        = var.key_vault_network_default_action
  scripts_dir                   = var.scripts_dir
  private_endpoint_dns_wait     = var.private_endpoint_dns_wait
  tags                          = module.naming.common_tags
}

module "postgres" {
  source                      = "../modules/postgres"
  name                        = var.postgres_server_name
  resource_group_name         = azurerm_resource_group.this.name
  location                    = var.location
  private_endpoints_subnet_id = module.network.private_endpoints_subnet_id
  postgres_version            = var.postgres_version
  sku_name                    = var.postgres_sku_name
  enable_high_availability    = var.postgres_enable_high_availability
  key_vault_name              = var.key_vault_name
  key_vault_id                = module.keyvault.id
  scripts_dir                 = var.scripts_dir
  private_endpoint_dns_wait   = var.private_endpoint_dns_wait
  tags                        = module.naming.common_tags
}

# ---------------------------------------------------------------------------
# Secrets written to Key Vault via az CLI (local-exec).
# Using null_resource + local-exec instead of azurerm_key_vault_secret so that
# secret VALUES are never written into the Terraform state file — only
# non-sensitive metadata (resource IDs, hashes) appear in triggers.
# ---------------------------------------------------------------------------

# ACR admin password — always overwrite (ACR can rotate it; trigger on hash).
resource "null_resource" "secret_acr_password" {
  triggers = {
    key_vault_id      = module.keyvault.id
    acr_password_hash = sha256(module.registry.admin_password)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME  = var.key_vault_name
      PASSWORD = module.registry.admin_password
      USERNAME = module.registry.admin_username
    }
    command = <<-EOT
      EXPIRES="$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)"
      az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name acr-password \
        --value "$PASSWORD" \
        --content-type "ACR admin password" \
        --expires "$EXPIRES" \
        -o none
      az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name acr-username \
        --value "$USERNAME" \
        --content-type "ACR admin username" \
        --expires "$EXPIRES" \
        -o none
    EOT
  }

  depends_on = [module.keyvault, module.registry]
}

# RabbitMQ password — generate once; skip if secret already exists.
resource "null_resource" "secret_rabbitmq_password" {
  triggers = {
    key_vault_id = module.keyvault.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME = var.key_vault_name
    }
    command = <<-EOT
      az keyvault secret show \
        --vault-name "$KV_NAME" \
        --name rabbitmq-password \
        --query id -o tsv 2>/dev/null \
      || az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name rabbitmq-password \
        --value "$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 28)" \
        --content-type "RabbitMQ password" \
        --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
        -o none
    EOT
  }

  depends_on = [module.keyvault]
}

# ACL admin password — generate once; skip if secret already exists.
resource "null_resource" "secret_acl_admin_password" {
  triggers = {
    key_vault_id = module.keyvault.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME = var.key_vault_name
    }
    command = <<-EOT
      az keyvault secret show \
        --vault-name "$KV_NAME" \
        --name acl-admin-password \
        --query id -o tsv 2>/dev/null \
      || az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name acl-admin-password \
        --value "{noop}$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 28)" \
        --content-type "GeoServer ACL admin password (Spring-encoded)" \
        --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
        -o none
    EOT
  }

  depends_on = [module.keyvault]
}

# ACL geoserver passwords — generate ONE random value, write both variants
# (Spring-encoded for ACL auth, plain for OWS clients) atomically from the
# same value so they always match. Skip if the plain version already exists.
resource "null_resource" "secret_acl_geoserver_passwords" {
  triggers = {
    key_vault_id = module.keyvault.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME = var.key_vault_name
    }
    command = <<-EOT
      az keyvault secret show \
        --vault-name "$KV_NAME" \
        --name acl-geoserver-password-plain \
        --query id -o tsv 2>/dev/null \
      || {
        pass="$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 28)"
        az keyvault secret set \
          --vault-name "$KV_NAME" \
          --name acl-geoserver-password \
          --value "{noop}$${pass}" \
          --content-type "GeoServer ACL geoserver-user password (Spring-encoded)" \
          --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
          -o none
        az keyvault secret set \
          --vault-name "$KV_NAME" \
          --name acl-geoserver-password-plain \
          --value "$${pass}" \
          --content-type "GeoServer ACL geoserver-user password (raw)" \
          --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
          -o none
      }
    EOT
  }

  depends_on = [module.keyvault]
}

# ---------------------------------------------------------------------------
# PostGIS extension initialisation
# Runs ONCE per database (config + geodata) inside the Container Apps
# Environment (already VNet-injected) so it can reach the private Postgres
# endpoint without any additional subnet or network change.
#
# Why a Container App Job and not null_resource local-exec:
#   The Postgres server has no public access (BC Gov ALZ policy). Direct psql
#   from the local machine would require routing raw TCP through the SOCKS5
#   proxy, which psql does not support natively. A Container App Job runs
#   INSIDE the VNet and reaches the private endpoint directly.
#
# The null_resource below starts the job via az CLI (management plane only —
# management.azure.com is in NO_PROXY so no SOCKS5 needed) and waits for it.
# ---------------------------------------------------------------------------
resource "azurerm_container_app_job" "init_postgis" {
  name                         = "init-postgis"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = var.location
  container_app_environment_id = module.container_app_environment.id
  workload_profile_name        = "Consumption"
  tags                         = module.naming.common_tags

  replica_timeout_in_seconds = 300
  replica_retry_limit        = 1

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [module.container_app_environment.uami_id]
  }

  registry {
    server               = module.registry.login_server
    username             = module.registry.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name                = "acr-password"
    identity            = module.container_app_environment.uami_id
    key_vault_secret_id = "${local._kv}/acr-password"
  }

  secret {
    name                = "postgres-password"
    identity            = module.container_app_environment.uami_id
    key_vault_secret_id = "${local._kv}/postgres-password"
  }

  template {
    container {
      name   = "init-postgis"
      image  = "${module.registry.login_server}/postgres:18-alpine"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "PGHOST"
        value = module.postgres.fqdn
      }
      env {
        name  = "PGUSER"
        value = module.postgres.administrator_login
      }
      env {
        name        = "PGPASSWORD"
        secret_name = "postgres-password"
      }
      env {
        name  = "PGSSLMODE"
        value = "require"
      }
      env {
        name  = "CONFIG_DB"
        value = module.postgres.config_database_name
      }
      env {
        name  = "DATA_DB"
        value = module.postgres.data_database_name
      }
      env {
        name  = "RESET_PGCONFIG"
        value = tostring(var.reset_pgconfig_schema)
      }
      env {
        name  = "PGCONFIG_SCHEMA"
        value = "pgconfig"
      }

      # Ensure PostGIS in both DBs. When RESET_PGCONFIG=true, drop the pgconfig
      # catalog schema first so a major GeoServer upgrade re-initializes it clean.
      # The acl schema is separate and untouched.
      command = [
        "/bin/sh", "-c",
        "set -e; if [ \"$RESET_PGCONFIG\" = \"true\" ]; then echo \"Dropping schema $PGCONFIG_SCHEMA in $CONFIG_DB...\"; psql -d \"$CONFIG_DB\" -c \"DROP SCHEMA IF EXISTS $PGCONFIG_SCHEMA CASCADE;\"; fi; psql -d \"$CONFIG_DB\" -c 'CREATE EXTENSION IF NOT EXISTS postgis;'; psql -d \"$DATA_DB\" -c 'CREATE EXTENSION IF NOT EXISTS postgis;'; echo 'PostGIS ready in both databases.'"
      ]
    }
  }

  depends_on = [
    module.postgres,
    module.container_app_environment,
    null_resource.secret_acr_password,
  ]
}

# Trigger the job on every apply where the server or job definition changes.
# The az containerapp job start call is a management-plane operation and does
# NOT require the SOCKS5 proxy (management.azure.com is in NO_PROXY).
resource "null_resource" "run_postgis_init" {
  triggers = {
    job_id     = azurerm_container_app_job.init_postgis.id
    server_id  = module.postgres.id
    gs_version = var.gs_cloud_version
    reset      = tostring(var.reset_pgconfig_schema)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      RG  = azurerm_resource_group.this.name
      JOB = azurerm_container_app_job.init_postgis.name
    }
    command = <<-EOT
      set -euo pipefail
      echo "Starting PostGIS init job..."
      RUN_ID=$(az containerapp job start --name "$JOB" --resource-group "$RG" --query name -o tsv)
      echo "Job execution: $RUN_ID"

      TIMEOUT=300
      ELAPSED=0
      while [ $ELAPSED -lt $TIMEOUT ]; do
        STATUS=$(az containerapp job execution show \
          --name "$JOB" \
          --resource-group "$RG" \
          --job-execution-name "$RUN_ID" \
          --query properties.status -o tsv 2>/dev/null || echo "Running")
        echo "  Status: $STATUS  ($${ELAPSED}s elapsed)"
        case "$STATUS" in
          Succeeded) echo "PostGIS init succeeded."; exit 0 ;;
          Failed)    echo "PostGIS init FAILED."; exit 1 ;;
          *)         sleep 15; ELAPSED=$((ELAPSED + 15)) ;;
        esac
      done
      echo "Timed out waiting for PostGIS init job."
      exit 1
    EOT
  }

  depends_on = [azurerm_container_app_job.init_postgis]
}

module "rabbitmq" {
  source                       = "../modules/rabbitmq"
  name                         = "rabbitmq"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = module.container_app_environment.id
  uami_id                      = module.container_app_environment.uami_id
  image                        = "${module.registry.login_server}/rabbitmq:${var.rabbitmq_image_tag}"
  registry_server              = module.registry.login_server
  registry_username            = module.registry.admin_username
  acr_password_secret_id       = "https://${var.key_vault_name}.vault.azure.net/secrets/acr-password"
  rabbitmq_user                = var.rabbitmq_user
  rabbitmq_password_secret_id  = "https://${var.key_vault_name}.vault.azure.net/secrets/rabbitmq-password"
  external_ingress             = true
  # min_replicas = 1: the broker MUST stay warm. TCP ingress has no scale trigger,
  # and at 0 the broker scales to zero and loses its (auto-delete) catalog-sync
  # queues — every service then logs "404 NOT_FOUND no queue ... in vhost '/'" and
  # catalog events stop propagating, causing intermittent 500s across the stack.
  min_replicas = 1
  tags         = module.naming.common_tags

  # Durable broker data dir — Azure File share (see rabbitmq-storage.tf).
  storage_account_name       = local.rabbitmq_storage_account_name
  file_share_name            = azurerm_storage_share.rabbitmq.name
  storage_account_access_key = local.rabbitmq_storage_account_key

  depends_on = [
    module.registry,
    null_resource.secret_acr_password,
    null_resource.secret_rabbitmq_password,
    azurerm_storage_share.rabbitmq,
  ]
}

module "acl" {
  source                        = "../modules/geoserver-service"
  name                          = "acl"
  resource_group_name           = azurerm_resource_group.this.name
  container_app_environment_id  = module.container_app_environment.id
  uami_id                       = module.container_app_environment.uami_id
  image                         = "${module.registry.login_server}/geoserver-acl:${var.acl_version}"
  registry_server               = module.registry.login_server
  registry_username             = module.registry.admin_username
  registry_password_secret_name = "acr-password"
  secrets                       = local.acl_secrets
  env                           = local.acl_env
  secret_env                    = local.acl_secret_env
  external_ingress              = true
  target_port                   = 8080
  transport                     = "auto"
  allow_insecure_connections    = false
  cpu                           = var.service_cpu
  memory                        = var.service_memory
  # min_replicas = 1: ACL sits on the authorization path of every secured OWS
  # request (services call ACL_URL to evaluate data-layer rules). At 0 it cold-starts
  # on the first request and stalls/fails authz; keep it warm.
  min_replicas = 1
  max_replicas = 1
  tags         = module.naming.common_tags

  depends_on = [
    module.registry,
    module.postgres,
    null_resource.secret_acr_password,
    null_resource.secret_rabbitmq_password,
    null_resource.secret_acl_admin_password,
    null_resource.secret_acl_geoserver_passwords,
    module.rabbitmq,
    null_resource.run_postgis_init,
  ]
}

module "service" {
  source   = "../modules/geoserver-service"
  for_each = local.services

  name                          = each.key
  resource_group_name           = azurerm_resource_group.this.name
  container_app_environment_id  = module.container_app_environment.id
  uami_id                       = module.container_app_environment.uami_id
  image                         = "${module.registry.login_server}/${each.value.repo}:${var.gs_cloud_version}"
  registry_server               = module.registry.login_server
  registry_username             = module.registry.admin_username
  registry_password_secret_name = "acr-password"
  secrets                       = local.service_secrets
  env                           = merge(local.common_env, each.value.extra_env)
  secret_env                    = local.common_secret_env
  external_ingress              = each.value.external
  target_port                   = each.value.port
  transport                     = "auto"
  allow_insecure_connections    = false
  # Per-service resource + scaling knobs (independent per GeoServer Cloud service,
  # defined in local.services). Fall back to the global var defaults if a service
  # entry omits one, so adding a service without these keys still plans cleanly.
  cpu             = try(each.value.cpu, var.service_cpu)
  memory          = try(each.value.memory, var.service_memory)
  sticky_sessions = each.value.sticky
  min_replicas    = each.value.min_replicas
  max_replicas    = try(each.value.max_replicas, var.service_max_replicas)
  tags            = module.naming.common_tags

  depends_on = [
    module.postgres,
    null_resource.secret_acr_password,
    null_resource.secret_rabbitmq_password,
    null_resource.secret_acl_geoserver_passwords,
    module.rabbitmq,
    module.acl,
    null_resource.run_postgis_init,
  ]
}

# WORKAROUND 1 — azurerm_container_app (azurerm 4.79) does not expose stickySessions
# in the ingress block. The ARM property (configuration.ingress.stickySessions.affinity)
# exists and is accepted by the ARM API, but the azurerm provider raises a validation
# error ("Blocks of type sticky_sessions are not expected here") if you add the block.
# Tracked: github.com/hashicorp/terraform-provider-azurerm
#
# Why webui needs it: webui is Wicket-based; its stateful page callbacks (AJAX,
# form submissions) must reach the same replica that rendered the page. Without
# affinity, GeoServer throws "Page expired" when the gateway routes to a different
# replica. The App Service (Node proxy) and GeoServer gateway both pass JSESSIONID
# through — the gateway uses JSESSIONID as the sticky key once affinity is enabled.
#
# Approach: azapi_update_resource sends a targeted ARM PATCH against the already-created
# Container App resource, setting only stickySessions.affinity without touching other
# properties. Remove this block and uncomment a sticky_sessions block inside the
# geoserver-service module once azurerm exposes the property.
resource "azapi_update_resource" "webui_sticky_sessions" {
  type        = "Microsoft.App/containerApps@2024-03-01"
  resource_id = module.service["webui"].id
  body = {
    properties = {
      configuration = {
        ingress = {
          stickySessions = {
            affinity = "sticky"
          }
        }
      }
    }
  }
  depends_on = [module.service]
}

# ---------------------------------------------------------------------------
# Node OIDC proxy — App Service (Linux container)
# ---------------------------------------------------------------------------

# Session cookie encryption key — generate once; skip if already exists.
# SECRET VALUE is NEVER in state: the az CLI prints nothing when -o none is set.
resource "null_resource" "secret_oidc_session_secret" {
  triggers = {
    key_vault_id = module.keyvault.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME = var.key_vault_name
    }
    command = <<-EOT
      az keyvault secret show \
        --vault-name "$KV_NAME" \
        --name oidc-session-secret \
        --query id -o tsv 2>/dev/null \
      || az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name oidc-session-secret \
        --value "$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)" \
        --content-type "OIDC proxy session cookie encryption key (>=32 bytes)" \
        --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
        -o none
    EOT
  }

  depends_on = [module.keyvault]
}

# Build the node-oidc-proxy Docker image and push it to ACR via ACR Tasks.
# ACR is Standard SKU + public_network_access_enabled = true, so az acr build
# (server-side build) runs without a local Docker daemon and without VNet access
# from the workstation. The trigger hash covers src/**,Dockerfile,package.json.
resource "null_resource" "build_proxy_image" {
  triggers = {
    acr_login_server = module.registry.login_server
    image_tag        = var.proxy_image_tag
    src_hash = sha256(join("", [
      for f in sort(fileset("${path.root}/../node-oidc-proxy/src", "**"))
      : filesha256("${path.root}/../node-oidc-proxy/src/${f}")
    ]))
    dockerfile_hash = filesha256("${path.root}/../node-oidc-proxy/Dockerfile")
    package_hash    = filesha256("${path.root}/../node-oidc-proxy/package.json")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      ACR_NAME  = var.acr_name
      IMAGE_TAG = var.proxy_image_tag
      CONTEXT   = "${path.root}/../node-oidc-proxy"
    }
    command = <<-EOT
      set -euo pipefail
      echo "Building node-oidc-proxy:$IMAGE_TAG into $ACR_NAME..."
      az acr build \
        --registry "$ACR_NAME" \
        --image "node-oidc-proxy:$IMAGE_TAG" \
        "$CONTEXT"
      echo "Done: $ACR_NAME.azurecr.io/node-oidc-proxy:$IMAGE_TAG"
    EOT
  }

  depends_on = [module.registry]
}

resource "azurerm_service_plan" "proxy" {
  name                = "asp-${module.naming.name_prefix}-proxy"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.proxy_sku
  tags                = module.naming.common_tags
}

# WORKAROUND 2 — azurerm_linux_web_app cannot be used for this App Service.
#
# Attempt 1 — azurerm_linux_web_app with DOCKER_REGISTRY_SERVER_* in app_settings:
#   The azurerm 4.79 provider rejects DOCKER_REGISTRY_SERVER_USERNAME and
#   DOCKER_REGISTRY_SERVER_PASSWORD in app_settings at plan time
#   ("cannot set a value for DOCKER_REGISTRY_SERVER_*"). The ACR admin password
#   cannot be passed in because the provider reserves these keys for its own
#   application_stack.docker_registry_* properties.
#
# Attempt 2 — azurerm_linux_web_app + acrUseManagedIdentityCreds:
#   Set DOCKER_ENABLE_CI=true, acrUseManagedIdentityCreds=true, and assigned AcrPull
#   on the system-assigned identity. App Service launches a _managedIdentity sidecar
#   to pull the image. On BC Gov ALZ the sidecar terminates before pulling succeeds:
#   "Site container: app-geoserver-proxy-tools_managedIdentity terminated"
#   Observed 17+ minutes after AcrPull role propagated — never recovered. Root cause
#   is likely ALZ Deny-PublicPaaSEndpoints policy blocking the sidecar's outbound path.
#
# Final approach — azapi_resource (Microsoft.Web/sites@2024-04-01):
#   The ARM API accepts @Microsoft.KeyVault(VaultName=...;SecretName=...) reference
#   strings for ANY app setting, including DOCKER_REGISTRY_SERVER_*. By going directly
#   to ARM via azapi, the azurerm provider's plan-time validation is bypassed.
#   KV reference STRINGS appear in Terraform state (not the resolved secret values).
#   The system-assigned identity resolves them at container startup via its
#   Key Vault Secrets User role assignment (see azurerm_role_assignment.proxy_kv_secrets_user).
resource "azapi_resource" "proxy" {
  type      = "Microsoft.Web/sites@2024-04-01"
  name      = var.proxy_app_service_name
  location  = var.location
  parent_id = azurerm_resource_group.this.id
  tags      = module.naming.common_tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "app,linux,container"
    properties = {
      serverFarmId           = azurerm_service_plan.proxy.id
      virtualNetworkSubnetId = module.network.app_service_subnet_id
      httpsOnly              = true

      siteConfig = {
        alwaysOn        = true
        healthCheckPath = "/healthz"
        # DOCKER|<registry>/<image>:<tag> is the linuxFxVersion format for container apps
        linuxFxVersion = "DOCKER|${module.registry.login_server}/node-oidc-proxy:${var.proxy_image_tag}"

        appSettings = [
          # Container port
          { name = "WEBSITES_PORT", value = "8080" },

          # ACR pull — credentials from KV (resolved at startup by the managed identity)
          { name = "DOCKER_REGISTRY_SERVER_URL", value = "https://${module.registry.login_server}" },
          { name = "DOCKER_REGISTRY_SERVER_USERNAME", value = "@Microsoft.KeyVault(VaultName=${var.key_vault_name};SecretName=acr-username)" },
          { name = "DOCKER_REGISTRY_SERVER_PASSWORD", value = "@Microsoft.KeyVault(VaultName=${var.key_vault_name};SecretName=acr-password)" },

          # OIDC / Keycloak
          { name = "OIDC_ISSUER", value = var.oidc_issuer },
          { name = "OIDC_CLIENT_ID", value = var.oidc_client_id },
          { name = "OIDC_REDIRECT_URI", value = "${local.proxy_origin}/auth/callback" },
          { name = "OIDC_POST_LOGOUT_REDIRECT_URI", value = "${local.proxy_origin}/" },
          { name = "OIDC_SCOPES", value = "openid profile email" },

          # Proxy configuration
          { name = "GATEWAY_ORIGIN", value = local.gateway_internal },
          { name = "PUBLIC_ORIGIN", value = local.proxy_origin },
          { name = "IDENTITY_HEADER", value = "sec-username" },
          # USERNAME_CLAIM: extract idir_user_guid from Keycloak token and inject as sec-username.
          # IDIR GUID is stable per user (survives account name changes, email updates).
          # GeoServer JDBC role service looks up roles in gssec.user_roles by this GUID.
          { name = "USERNAME_CLAIM", value = "idir_user_guid" },
          # DISPLAY_NAME_*: extract display_name from token and inject as sec-user-display-name header.
          # GeoServer UI uses this for human-readable display instead of the GUID.
          { name = "DISPLAY_NAME_HEADER", value = "sec-user-display-name" },
          { name = "DISPLAY_NAME_CLAIM", value = "display_name" },
          { name = "MACHINE_AUTH_PASSTHROUGH", value = "true" },
          { name = "SESSION_COOKIE_NAME", value = "gs_sso" },
          { name = "SESSION_MAX_AGE_SECONDS", value = "43200" },
          { name = "LOG_LEVEL", value = "info" },
          # Upstream timeouts. The proxy's "connect" timer actually fires if no
          # RESPONSE arrives in time (it is cleared on first response byte), so it
          # must cover a scale-to-zero OWS backend cold-start (wms/wfs/wcs/gwc/rest
          # are min_replicas=0). At the 5s default a cold backend 502s; 90s lets it
          # cold-start then respond. READ timeout covers large WMS/WFS payloads.
          { name = "GATEWAY_CONNECT_TIMEOUT_MS", value = "90000" },
          { name = "GATEWAY_READ_TIMEOUT_MS", value = "180000" },

          # KV references — reference strings (not values) in state; resolved at runtime
          { name = "OIDC_CLIENT_SECRET", value = "@Microsoft.KeyVault(VaultName=${var.key_vault_name};SecretName=OIDC-CLIENT-SECRET)" },
          { name = "SESSION_COOKIE_SECRET", value = "@Microsoft.KeyVault(VaultName=${var.key_vault_name};SecretName=oidc-session-secret)" },
        ]
      }
    }
  }

  response_export_values = ["*"]

  depends_on = [
    module.network,
    null_resource.build_proxy_image,
    null_resource.secret_oidc_session_secret,
  ]
}

# Key Vault Secrets User — resolves KV references in appSettings at startup
# (DOCKER_REGISTRY_SERVER_PASSWORD, OIDC_CLIENT_SECRET, SESSION_COOKIE_SECRET)
resource "azurerm_role_assignment" "proxy_kv_secrets_user" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azapi_resource.proxy.output.identity.principalId

  # The proxy's system-assigned principalId is STABLE, but it is read from an
  # azapi_resource output that Terraform treats as known-after-apply on every run,
  # which otherwise REPLACES this role assignment each apply. The replace window
  # strips the proxy identity's Key Vault access, so App Service can't resolve the
  # KV-referenced DOCKER_REGISTRY_SERVER_PASSWORD at its next restart -> the image
  # pull fails (ImagePullUnauthorizedFailure) and the proxy 503s until RBAC
  # re-propagates and the app is stopped/started. Ignoring principal_id changes
  # after creation keeps the assignment stable so applies stop breaking the proxy.
  lifecycle {
    ignore_changes = [principal_id]
  }
}

# ---------------------------------------------------------------------------
# Stage 3 — GeoServer security
#
# Architecture:
#   Node proxy (App Service) injects sec-username into every request to the ACA
#   gateway. The gateway forwards it to backend services. GeoServer is configured
#   with a request-header pre-auth filter that trusts sec-username as the
#   authenticated identity (fall-through to HTTP Basic for local-admin access via
#   the SOCKS5 proxy). Roles are resolved from a JDBC role service backed by the
#   same pgconfig PostgreSQL database.
#
#   Admin bootstrap: the environment-admin-auth Spring profile reads
#   GEOSERVER_ADMIN_USERNAME / GEOSERVER_ADMIN_PASSWORD at startup — admin
#   credentials are deterministic across all replicas without touching the
#   ephemeral data directory. The password lives in Key Vault; the env var
#   reference is in common_secret_env.
# ---------------------------------------------------------------------------

# GeoServer web-admin password — generate once, skip if already exists.
# Value never in state; the az CLI -o none output produces no text.
resource "null_resource" "secret_geoserver_admin_password" {
  triggers = {
    key_vault_id = module.keyvault.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME = var.key_vault_name
    }
    command = <<-EOT
      az keyvault secret show \
        --vault-name "$KV_NAME" \
        --name geoserver-admin-password \
        --query id -o tsv 2>/dev/null \
      || az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name geoserver-admin-password \
        --value "$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 28)" \
        --content-type "GeoServer web-admin password (environment-admin-auth)" \
        --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
        -o none
    EOT
  }

  depends_on = [module.keyvault]
}

# ---------------------------------------------------------------------------
# JDBC role service schema initialisation
# Creates GeoServer's role-service tables in a dedicated gssec schema inside the
# pgconfig database. The table shapes MUST match GeoServer's built-in role DML
# (src/security/jdbc/.../rolesdml.xml) — that is enforced by the SQL below.
#
# Table layout (GeoServer JDBCRoleService contract):
#   gssec.roles(name VARCHAR PK, parent VARCHAR)
#   gssec.role_props(rolename, propname, propvalue, PK(rolename,propname))
#   gssec.user_roles(username VARCHAR, rolename VARCHAR, PK(both)) + idx
#     where username is the IDIR GUID injected as sec-username by the Node proxy.
#   gssec.group_roles(groupname VARCHAR, rolename VARCHAR, PK(both)) + idx
#   gssec.user_display_names(idir_user_guid PK, display_name) — friendly UI name.
#
# The role service is wired to these tables over the pgconfig JNDI datasource
# (java:comp/env/jdbc/pgconfig) using gssec-schema-qualified DML uploaded by
# null_resource.configure_geoserver_security — so NO database password lives in
# the security config (it reuses the catalog datasource's credentials).
#
# Runs inside the Container Apps Environment (VNet-injected) so it can reach the
# private Postgres endpoint without routing raw TCP through the SOCKS5 proxy.
# ---------------------------------------------------------------------------
resource "azurerm_container_app_job" "init_gsroles" {
  name                         = "init-gsroles"
  resource_group_name          = azurerm_resource_group.this.name
  location                     = var.location
  container_app_environment_id = module.container_app_environment.id
  workload_profile_name        = "Consumption"
  tags                         = module.naming.common_tags

  replica_timeout_in_seconds = 120
  replica_retry_limit        = 1

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [module.container_app_environment.uami_id]
  }

  registry {
    server               = module.registry.login_server
    username             = module.registry.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name                = "acr-password"
    identity            = module.container_app_environment.uami_id
    key_vault_secret_id = "${local._kv}/acr-password"
  }

  secret {
    name                = "postgres-password"
    identity            = module.container_app_environment.uami_id
    key_vault_secret_id = "${local._kv}/postgres-password"
  }

  template {
    container {
      name   = "init-gsroles"
      image  = "${module.registry.login_server}/postgres:18-alpine"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "PGHOST"
        value = module.postgres.fqdn
      }
      env {
        name  = "PGUSER"
        value = module.postgres.administrator_login
      }
      env {
        name  = "PGSSLMODE"
        value = "require"
      }
      env {
        name  = "PGDATABASE"
        value = module.postgres.config_database_name
      }
      env {
        name        = "PGPASSWORD"
        secret_name = "postgres-password"
      }

      # Create the gssec schema + the EXACT tables GeoServer's JDBCRoleService
      # expects (column names and the role_props / group_roles tables matter:
      # the built-in role DML runs `select name,parent from roles`, checks for
      # `role_props`, and joins `group_roles`). Mirrors GeoServer's rolesddl.xml
      # (src/security/jdbc/.../rolesddl.xml) but in a dedicated gssec schema so a
      # pgconfig catalog reset never drops the security tables.
      #
      # DROP first: the gssec tables hold no production data yet (roles are assigned
      # manually post-bootstrap), and the first apply created an incompatible schema
      # (parent_name, missing role_props/group_roles). DROP CASCADE guarantees the
      # correct shape regardless of what a prior run created.
      command = [
        "/bin/sh", "-c", <<-EOT
          set -e
          psql <<'SQL'
            CREATE SCHEMA IF NOT EXISTS gssec;

            DROP TABLE IF EXISTS gssec.user_roles  CASCADE;
            DROP TABLE IF EXISTS gssec.group_roles CASCADE;
            DROP TABLE IF EXISTS gssec.role_props  CASCADE;
            DROP TABLE IF EXISTS gssec.roles       CASCADE;

            CREATE TABLE gssec.roles (
              name   VARCHAR(64) NOT NULL,
              parent VARCHAR(64),
              PRIMARY KEY (name)
            );

            CREATE TABLE gssec.role_props (
              rolename  VARCHAR(64)   NOT NULL,
              propname  VARCHAR(64)   NOT NULL,
              propvalue VARCHAR(2048),
              PRIMARY KEY (rolename, propname)
            );

            CREATE TABLE gssec.user_roles (
              username VARCHAR(128) NOT NULL,
              rolename VARCHAR(64)  NOT NULL,
              PRIMARY KEY (username, rolename)
            );
            CREATE INDEX user_roles_idx ON gssec.user_roles (rolename, username);

            CREATE TABLE gssec.group_roles (
              groupname VARCHAR(128) NOT NULL,
              rolename  VARCHAR(64)  NOT NULL,
              PRIMARY KEY (groupname, rolename)
            );
            CREATE INDEX group_roles_idx ON gssec.group_roles (rolename, groupname);

            -- GUID -> friendly name (for the GeoServer UI; populated as users log in).
            CREATE TABLE IF NOT EXISTS gssec.user_display_names (
              idir_user_guid VARCHAR(128) NOT NULL PRIMARY KEY,
              display_name   VARCHAR(255) NOT NULL
            );

            -- Seed the well-known GeoServer roles. ROLE_ADMINISTRATOR is the admin
            -- role the role service maps to (adminRoleName in role-service config.xml).
            INSERT INTO gssec.roles(name) VALUES ('ROLE_ADMINISTRATOR') ON CONFLICT DO NOTHING;
            INSERT INTO gssec.roles(name) VALUES ('ROLE_GROUP_ADMIN')   ON CONFLICT DO NOTHING;
            INSERT INTO gssec.roles(name) VALUES ('ROLE_AUTHENTICATED') ON CONFLICT DO NOTHING;
          SQL
          echo "gssec schema ready."
        EOT
      ]
    }
  }

  depends_on = [
    module.postgres,
    module.container_app_environment,
    null_resource.secret_acr_password,
    null_resource.run_postgis_init,
  ]
}

resource "null_resource" "run_gsroles_init" {
  triggers = {
    job_id    = azurerm_container_app_job.init_gsroles.id
    server_id = module.postgres.id
    # Bump when the gssec schema definition changes so the job re-runs (the job's
    # resource ID is stable across in-place command edits, so it alone won't retrigger).
    schema_version = "v2-geoserver-compatible"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      RG  = azurerm_resource_group.this.name
      JOB = azurerm_container_app_job.init_gsroles.name
    }
    command = <<-EOT
      set -euo pipefail
      echo "Starting gsroles init job..."
      RUN_ID=$(az containerapp job start --name "$JOB" --resource-group "$RG" --query name -o tsv)
      echo "Execution: $RUN_ID"
      TIMEOUT=120; ELAPSED=0
      while [ $ELAPSED -lt $TIMEOUT ]; do
        STATUS=$(az containerapp job execution show \
          --name "$JOB" --resource-group "$RG" \
          --job-execution-name "$RUN_ID" \
          --query properties.status -o tsv 2>/dev/null || echo "Running")
        echo "  $STATUS ($${ELAPSED}s)"
        case "$STATUS" in
          Succeeded) echo "gsroles init succeeded."; exit 0 ;;
          Failed)    echo "gsroles init FAILED."; exit 1 ;;
          *)         sleep 10; ELAPSED=$((ELAPSED + 10)) ;;
        esac
      done
      echo "Timed out."; exit 1
    EOT
  }

  depends_on = [azurerm_container_app_job.init_gsroles]
}

# ---------------------------------------------------------------------------
# GeoServer security configuration (over the SOCKS5 bastion tunnel to the ACA
# gateway). Runs after services are up; re-runs when the config version, gateway,
# admin password, or gssec schema changes.
#
# IMPORTANT — why this uses the endpoints it does (verified against 3.0.0-CLOUD):
#   * Role SERVICES have NO dedicated REST endpoint (/rest/security/roleservices
#     is 404). They are written as resource files via the generic Resource REST
#     API (/rest/resource/security/role/<name>/...). Those files live in the
#     pgconfig `resourcestore` table, so the config is SHARED across every
#     microservice replica and survives restarts — this is the "shared data
#     directory" realised through the pgconfig database instead of an Azure File
#     mount (no extra storage, no mount-coexistence risk).
#   * Auth FILTERS do have a REST endpoint, but it is /rest/security/authfilters
#     (NOT /rest/security/auth/filters — that 404s). It goes through the security
#     manager (validates + activates), so we use it for the header filter.
#   * The role service uses the pgconfig JNDI datasource (java:comp/env/jdbc/pgconfig)
#     plus gssec-schema-qualified DML, so NO database password is stored in the
#     security config (it reuses the catalog datasource credentials).
#
# Pre-requisites:
#   - SOCKS5 proxy at 127.0.0.1:8228 (bastion tunnel) — see local-run.sh.
#   - geoserver-admin-password secret in Key Vault.
#   - gssec tables initialised (null_resource.run_gsroles_init).
# ---------------------------------------------------------------------------
resource "null_resource" "configure_geoserver_security" {
  triggers = {
    gateway_id   = module.service["gateway"].id
    admin_secret = null_resource.secret_geoserver_admin_password.id
    gsroles_init = null_resource.run_gsroles_init.id
    # Re-apply when the security-config script changes.
    script_sha = filesha256("${path.module}/../scripts/configure-geoserver-security.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME     = var.key_vault_name
      GATEWAY_URL = local.gateway_internal
    }
    # The logic lives in a standalone, syntax-checkable script (bash -n) rather
    # than an inline heredoc — inline Terraform-heredoc-inside-bash escaping
    # (%%{...}, $${...}, nested heredocs) is error-prone and cannot be linted.
    command = "bash '${path.module}/../scripts/configure-geoserver-security.sh'"
  }

  depends_on = [
    module.service,
    null_resource.run_gsroles_init,
    null_resource.secret_geoserver_admin_password,
    azapi_update_resource.webui_sticky_sessions,
  ]
}
