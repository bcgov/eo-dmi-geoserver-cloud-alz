# modules/rabbitmq
# RabbitMQ event bus for GeoServer Cloud catalog synchronization, deployed as an
# internal Container App (TCP ingress on 5672). There is no managed RabbitMQ in
# Azure, so we run the upstream image (imported into ACR). Credentials come from
# Key Vault via the shared user-assigned identity.

resource "azurerm_container_app" "rabbitmq" {
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

  registry {
    server               = var.registry_server
    username             = var.registry_username
    password_secret_name = "acr-password"
  }

  secret {
    name                = "acr-password"
    identity            = var.uami_id
    key_vault_secret_id = var.acr_password_secret_id
  }

  secret {
    name                = "rabbitmq-password"
    identity            = var.uami_id
    key_vault_secret_id = var.rabbitmq_password_secret_id
  }

  ingress {
    external_enabled = var.external_ingress
    target_port      = 5672
    exposed_port     = 5672
    transport        = "tcp"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "rabbitmq"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "RABBITMQ_DEFAULT_USER"
        value = var.rabbitmq_user
      }
      env {
        name        = "RABBITMQ_DEFAULT_PASS"
        secret_name = "rabbitmq-password"
      }
    }
  }
}
