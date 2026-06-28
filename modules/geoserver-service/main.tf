# modules/geoserver-service
# Generic reusable module = ONE GeoServer Cloud microservice as a Container App.
# The stack instantiates this once per service (gateway, web-ui, wms, wfs, wcs,
# wps, rest, gwc) via for_each over a services map.
#
# Auth model: ACR pull uses admin username + a password sourced from Key Vault
# (per the Standard-ACR decision). Application secrets (DB/RabbitMQ passwords)
# are Key Vault references resolved by the shared user-assigned identity.

resource "azurerm_container_app" "this" {
  name                         = var.name
  container_app_environment_id = var.container_app_environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.uami_id]
  }

  # ACR pull credentials (Standard ACR, admin user). The password lives in Key
  # Vault and is exposed to the app as the secret named var.registry_password_secret_name.
  registry {
    server               = var.registry_server
    username             = var.registry_username
    password_secret_name = var.registry_password_secret_name
  }

  # Key Vault-referenced secrets (incl. the ACR password). Resolved at runtime by
  # the user-assigned identity, which holds "Key Vault Secrets User".
  dynamic "secret" {
    for_each = { for s in var.secrets : s.name => s }
    content {
      name                = secret.value.name
      identity            = var.uami_id
      key_vault_secret_id = secret.value.key_vault_secret_id
    }
  }

  ingress {
    # external_enabled = true exposes the app on the environment's INTERNAL load
    # balancer (the environment itself has no public IP). Only the gateway needs
    # to be reachable from the VNet; sibling services use internal-only ingress.
    #
    # stickySessions is NOT declared here: azurerm_container_app (azurerm ≥4.79) raises
    # "Blocks of type sticky_sessions are not expected here" even though the ARM API accepts
    # the property. The stack patches it via azapi_update_resource after creation.
    external_enabled           = var.external_ingress
    target_port                = var.target_port
    transport                  = var.transport
    allow_insecure_connections = var.allow_insecure_connections

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = var.name
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      # Plain (non-secret) environment variables.
      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      # Secret-backed environment variables (value pulled from a named secret).
      dynamic "env" {
        for_each = { for e in var.secret_env : e.name => e }
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }
    }
  }
}
