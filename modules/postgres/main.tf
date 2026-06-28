# modules/postgres
# Azure Database for PostgreSQL Flexible Server reached over a private endpoint
# (public access disabled). Hosts two databases:
#   * the GeoServer Cloud "pgconfig" catalog (centralized config backend), and
#   * a PostGIS-enabled database for geospatial data.
# The admin password is generated here and surfaced as a sensitive output; the
# calling stack stores it in Key Vault.

resource "random_password" "admin" {
  length           = 28
  special          = true
  override_special = "!#$%*-_=+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version

  administrator_login    = var.administrator_login
  administrator_password = random_password.admin.result
  auto_grow_enabled       = true
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  # Private-endpoint networking: no public access, no delegated subnet.
  public_network_access_enabled = false

  dynamic "high_availability" {
    for_each = var.enable_high_availability ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
    # zone: Azure may move the primary zone out of band.
    # administrator_password: generated once; never rotated by Terraform.
    # version: in-place major upgrades are handled by null_resource.postgres_upgrade below;
    #          changing version here would trigger a ForceNew which is blocked by prevent_destroy.
    ignore_changes = [zone, administrator_password, version]
  }
}

# =============================================================================
# IN-PLACE MAJOR VERSION UPGRADE
# Azure Flexible Server supports in-place major-version upgrades via the
# management plane (no direct DB connectivity required). The server resource
# ignores the version attribute to prevent a ForceNew; this null_resource
# drives the upgrade when var.postgres_version changes. Idempotent: exits
# immediately if the server is already at the target version.
# =============================================================================
resource "null_resource" "postgres_upgrade" {
  triggers = {
    target_version = var.postgres_version
    server_id      = azurerm_postgresql_flexible_server.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      SERVER_ID           = azurerm_postgresql_flexible_server.this.id
      TARGET_VERSION      = var.postgres_version
      MSYS_NO_PATHCONV    = "1"
      MSYS2_ARG_CONV_EXCL = "*"
    }
    command = <<-EOT
      set -euo pipefail
      CURRENT=$(az postgres flexible-server show --ids "$SERVER_ID" --query version -o tsv)
      if [ "$CURRENT" = "$TARGET_VERSION" ]; then
        echo "PostgreSQL already at version $TARGET_VERSION — no upgrade needed."
        exit 0
      fi
      echo "Upgrading PostgreSQL from $CURRENT to $TARGET_VERSION ..."
      az postgres flexible-server upgrade \
        --ids "$SERVER_ID" \
        --version "$TARGET_VERSION" \
        --yes
      echo "Upgrade complete."
    EOT
  }

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_private_endpoint.this,
  ]
}

# Allowlist the geospatial extensions before any CREATE EXTENSION is run.
# Must wait for PE creation; attaching a PE triggers a server-side operation
# that causes ServerIsBusy if config changes run concurrently.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = var.azure_extensions

  depends_on = [azurerm_private_endpoint.this, null_resource.postgres_upgrade]
}

resource "azurerm_postgresql_flexible_server_database" "config" {
  name      = var.config_database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [azurerm_private_endpoint.this]
}

resource "azurerm_postgresql_flexible_server_database" "data" {
  name      = var.data_database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [azurerm_private_endpoint.this]
}

resource "azurerm_private_endpoint" "this" {
  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_postgresql_flexible_server.this.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags, private_dns_zone_group]
  }
}

# =============================================================================
# WAIT FOR POLICY-MANAGED DNS ZONE GROUP
# BC Gov ALZ policy attaches the zone group asynchronously after PE creation.
# Downstream resources (pgconfig connections, secret writes) must not proceed
# until the PE's DNS resolves inside the VNet.
# =============================================================================
resource "null_resource" "wait_for_dns" {
  count = var.scripts_dir != "" ? 1 : 0

  triggers = {
    private_endpoint_id   = azurerm_private_endpoint.this.id
    resource_group_name   = var.resource_group_name
    private_endpoint_name = azurerm_private_endpoint.this.name
    timeout               = var.private_endpoint_dns_wait.timeout
    interval              = var.private_endpoint_dns_wait.poll_interval
    scripts_dir           = var.scripts_dir
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      ${self.triggers.scripts_dir}/wait-for-dns-zone.sh \
        --resource-group ${self.triggers.resource_group_name} \
        --private-endpoint-name ${self.triggers.private_endpoint_name} \
        --timeout ${self.triggers.timeout} \
        --interval ${self.triggers.interval}
    EOT
  }

  depends_on = [azurerm_private_endpoint.this]
}

# =============================================================================
# WRITE POSTGRES PASSWORD TO KEY VAULT
# Writes the admin password directly via az CLI so the value never appears as
# a Terraform resource attribute in state (azurerm_key_vault_secret stores
# .value in state; local-exec environment variables do not).
# The key_vault_id trigger creates a data dependency that ensures KV (including
# its DNS zone group wait) is provisioned before this runs.
# Always overwrites: if the server is recreated, the new password is correct.
# =============================================================================
resource "null_resource" "write_password_to_kv" {
  triggers = {
    server_id    = azurerm_postgresql_flexible_server.this.id
    key_vault_id = var.key_vault_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KV_NAME  = var.key_vault_name
      PASSWORD = random_password.admin.result
    }
    command = <<-EOT
      az keyvault secret set \
        --vault-name "$KV_NAME" \
        --name postgres-password \
        --value "$PASSWORD" \
        --content-type "PostgreSQL admin password" \
        --expires "$(date -u -d '+89 days' +%Y-%m-%dT%H:%M:%SZ)" \
        -o none
    EOT
  }

  depends_on = [null_resource.wait_for_dns]
}
