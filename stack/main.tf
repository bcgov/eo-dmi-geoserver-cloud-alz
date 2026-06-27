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

      command = [
        "/bin/sh", "-c",
        "psql -d \"$CONFIG_DB\" -c 'CREATE EXTENSION IF NOT EXISTS postgis;' && psql -d \"$DATA_DB\" -c 'CREATE EXTENSION IF NOT EXISTS postgis;' && echo 'PostGIS installed in both databases.'"
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
    job_id    = azurerm_container_app_job.init_postgis.id
    server_id = module.postgres.id
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
  min_replicas                 = var.service_min_replicas
  tags                         = module.naming.common_tags

  depends_on = [
    module.registry,
    null_resource.secret_acr_password,
    null_resource.secret_rabbitmq_password,
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
  min_replicas                  = var.service_min_replicas
  max_replicas                  = 1
  tags                          = module.naming.common_tags

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
  cpu                           = var.service_cpu
  memory                        = var.service_memory
  min_replicas                  = var.service_min_replicas
  max_replicas                  = var.service_max_replicas
  tags                          = module.naming.common_tags

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
