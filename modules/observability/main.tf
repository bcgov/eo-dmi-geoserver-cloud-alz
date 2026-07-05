# modules/observability
# Log Analytics workspace that backs the Container Apps environment's logs.

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days
  tags                = var.tags

  lifecycle {
    ignore_changes = [tags]
  }
}
