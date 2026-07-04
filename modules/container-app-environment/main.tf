# modules/container-app-environment
# The Container Apps environment that hosts every GeoServer Cloud microservice,
# plus the shared user-assigned managed identity the apps use to pull from ACR
# and read secrets from Key Vault.
#
# BC Gov ALZ posture:
#   * internal_load_balancer_enabled = true  -> no public IP; the environment is
#     reachable only from within the spoke VNet (the gateway is the sole app with
#     external ingress, exposed on this internal load balancer).
#   * infrastructure_subnet_id points at the platform-provided subnet delegated
#     to "Microsoft.App/environments".
#   * infrastructure_resource_group_name = "ME-<rg>" is the managed resource
#     group Azure creates for the environment's internal infrastructure.
#
# A "Consumption" workload profile is always declared (workload-profiles mode),
# which supports the documented /27 infrastructure subnet. Additional dedicated
# profiles are configured via var.workload_profiles.

resource "azurerm_container_app_environment" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  log_analytics_workspace_id         = var.enable_diagnostics ? var.log_analytics_workspace_id : null
  infrastructure_subnet_id           = var.infrastructure_subnet_id
  infrastructure_resource_group_name = "ME-${var.resource_group_name}"
  internal_load_balancer_enabled     = var.internal_load_balancer_enabled
  zone_redundancy_enabled            = var.zone_redundancy_enabled
  mutual_tls_enabled                 = var.mtls_enabled

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  dynamic "workload_profile" {
    for_each = var.workload_profiles
    content {
      name                  = workload_profile.value.name
      workload_profile_type = workload_profile.value.workload_profile_type
      minimum_count         = workload_profile.value.minimum_count
      maximum_count         = workload_profile.value.maximum_count
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [tags]
  }
}

# -----------------------------------------------------------------------------
# Fix Log Analytics Configuration
# -----------------------------------------------------------------------------
# The azurerm_container_app_environment resource doesn't properly set the
# Log Analytics shared key. Use azapi to patch the configuration.
resource "azapi_update_resource" "container_app_env_logs" {
  count = var.enable_diagnostics ? 1 : 0

  type        = "Microsoft.App/managedEnvironments@2024-03-01"
  resource_id = azurerm_container_app_environment.this.id

  body = {
    properties = {
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = var.log_analytics_workspace_customer_id
          sharedKey  = var.log_analytics_workspace_key
        }
      }
    }
  }

  depends_on = [azurerm_container_app_environment.this]
}



# Shared identity for all GeoServer Cloud apps. Granted "Key Vault Secrets User"
# by the keyvault module and used as the ACR pull / secret-resolution identity by
# every Container App.
# Private Endpoint for the CAE internal load balancer.
# Required in BC Gov ALZ so the centralized hub DNS forwarder can resolve
# *.canadacentral.azurecontainerapps.io to the private VIP — without this,
# Bastion sessions and App Gateway backends can't resolve the gateway FQDN.
# BC Gov ALZ policy attaches the DNS zone group asynchronously after PE creation.
resource "azurerm_private_endpoint" "this" {
  count               = var.private_endpoints_subnet_id != "" ? 1 : 0
  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_app_environment.this.id
    subresource_names              = ["managedEnvironments"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags, private_dns_zone_group]
  }
}

resource "azurerm_user_assigned_identity" "apps" {
  name                = var.uami_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}
