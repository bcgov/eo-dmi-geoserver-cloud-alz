# modules/keyvault
# RBAC-authorized Key Vault that holds the platform's secrets (Postgres admin
# password, ACR admin password, RabbitMQ credentials). A private endpoint gives
# the Container Apps private, in-VNet access. DNS is registered automatically
# by BC Gov platform policy in the centralized hub Private DNS Zone.
#
# Secret-write access: the Terraform deploy identity needs "Key Vault Secrets
# Officer". Runtime read access: the Container Apps user-assigned identity needs
# "Key Vault Secrets User". Both are wired via role assignments below.

resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # RBAC instead of legacy access policies.
  rbac_authorization_enabled = true

  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  # NOTE (bootstrap default): public access is left enabled with an AzureServices
  # bypass so a Microsoft-hosted GitHub runner can write secrets on first apply.
  # HARDEN for production: set public_network_access_enabled = false and
  # network_default_action = "Deny", and run Terraform from inside the VNet
  # (self-hosted runner or Bastion) so secret writes traverse the private endpoint.
  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    default_action = var.network_default_action
    bypass         = "AzureServices"
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_private_endpoint" "this" {
  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoints_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  lifecycle {
    # tags: managed externally / by policy; private_dns_zone_group: attached
    # asynchronously by BC Gov ALZ platform policy — never let Terraform touch it.
    ignore_changes = [tags, private_dns_zone_group]
  }
}

# =============================================================================
# WAIT FOR POLICY-MANAGED DNS ZONE GROUP
# BC Gov ALZ policy attaches the zone group asynchronously after PE creation.
# Downstream resources (Key Vault secret writes) must not run until DNS resolves.
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

# Runtime read access for the Container Apps managed identity (and any other
# reader principals supplied).
resource "azurerm_role_assignment" "secrets_user" {
  # Index-keyed map so Terraform can determine the for_each keys at plan time
  # even when the principal IDs are only known after apply (e.g. UAMI).
  for_each             = { for i, v in var.reader_principal_ids : tostring(i) => v }
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

# Secret-write access for the Terraform deploy identity (and any other admins).
resource "azurerm_role_assignment" "secrets_officer" {
  for_each             = { for i, v in var.admin_principal_ids : tostring(i) => v }
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}
