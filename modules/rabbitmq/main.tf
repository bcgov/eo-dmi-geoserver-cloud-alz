# modules/rabbitmq
# RabbitMQ event bus for GeoServer Cloud catalog synchronization, deployed as an
# internal Container App (TCP ingress on 5672). There is no managed RabbitMQ in
# Azure, so we run the upstream image (imported into ACR). Credentials come from
# Key Vault via the shared user-assigned identity.
#
# Durability: the node data dir (/var/lib/rabbitmq) is backed by an Azure File
# share registered with the Container Apps Environment, so broker state survives
# container restarts/redeploys instead of living on the ephemeral container layer.
# A STABLE RABBITMQ_NODENAME is required for this to actually work — Mnesia stores
# its DB under /var/lib/rabbitmq/mnesia/<nodename>, and the ACA replica hostname
# changes on every restart, so without a fixed node name each restart would create
# a fresh empty dir on the volume and the old state would be orphaned.

# Azure File share registered with the Container Apps Environment. The actual
# storage account + file share are created in the stack and passed in; this only
# wires them into the environment so the container can mount the share by name.
resource "azurerm_container_app_environment_storage" "rabbitmq_data" {
  name                         = "rabbitmq-data"
  container_app_environment_id = var.container_app_environment_id
  account_name                 = var.storage_account_name
  share_name                   = var.file_share_name
  access_key                   = var.storage_account_access_key
  access_mode                  = "ReadWrite"
}

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
    # TODO(before live demos / prod): set min_replicas = 1 so the event bus stays
    # warm. The POC keeps it at var.min_replicas (currently 0 → scale-to-zero), but
    # TCP ingress has NO built-in scale trigger, so at 0 the broker can sit cold
    # with nothing to wake it and catalog-change events will not propagate.
    # max_replicas stays 1: this is a single-node broker — do NOT scale it out
    # (independent replicas behind one ingress would silently drop bus messages;
    # horizontal scale would require real RabbitMQ clustering, not present here).
    min_replicas = var.min_replicas
    max_replicas = 1

    # Persistent broker data dir (Mnesia/Khepri DB, definitions, durable messages).
    volume {
      name         = "rabbitmq-data"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.rabbitmq_data.name
    }

    container {
      name   = "rabbitmq"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      # Mount the durable share at the MNESIA dir, NOT at /var/lib/rabbitmq.
      #
      # Why the subdir: /var/lib/rabbitmq is the rabbitmq user's $HOME, where Erlang
      # keeps `.erlang.cookie`. Erlang requires that file to be 0600 (owner-only) or
      # the broker aborts at prelaunch:
      #   "Cookie file /var/lib/rabbitmq/.erlang.cookie must be accessible by owner only"
      #   -> Kernel pid terminated (application_controller) ... crash loop.
      # Azure File (SMB) mounts every file 0777 and IGNORES chmod, so mounting the
      # share at $HOME makes the cookie un-fixable and RabbitMQ never starts (that
      # crash loop manifested upstream as "404 NOT_FOUND no queue ... in vhost '/'"
      # on every GeoServer service and intermittent OWS 500s).
      # Mounting only the Mnesia data dir keeps durability while leaving the cookie
      # on the container's local fs where 0600 holds.
      volume_mounts {
        name = "rabbitmq-data"
        path = "/var/lib/rabbitmq/mnesia"
      }

      # Stable node name → stable Mnesia dir (/var/lib/rabbitmq/mnesia/rabbit@localhost,
      # which is on the mounted share) so persisted state is reused across restarts
      # regardless of the changing ACA replica hostname.
      env {
        name  = "RABBITMQ_NODENAME"
        value = "rabbit@localhost"
      }
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
