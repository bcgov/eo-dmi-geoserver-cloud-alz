# modules/registry
# Azure Container Registry via Azure Verified Module (AVM), plus Terraform-native
# image sourcing.
#
# Decision (confirmed): Standard SKU, admin credentials, NO private endpoint.
# This is accepted in the BC Gov ALZ. (Premium is only required when ACR uses a
# private endpoint.) The admin username/password are exported as sensitive
# outputs; the calling stack writes them into Key Vault and the Container Apps
# reference them as registry credentials.
#
# Images are pulled into the registry by Terraform using the server-side ACR
# `importImage` action (azapi). This replaces the former scripts/import-images.sh
# step: no Docker daemon and no `az acr import` shell-out are required, and the
# import happens as part of `terraform apply` before the Container Apps start.
#
# AVM source: https://github.com/Azure/terraform-azurerm-avm-res-containerregistry-registry

module "container_registry" {
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "0.5.1"

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku                     = var.sku
  admin_enabled           = var.admin_enabled
  zone_redundancy_enabled = false

  # Standard SKU: public access, no private endpoint required in BC Gov ALZ.
  public_network_access_enabled = true
  anonymous_pull_enabled        = false

  # Retention policy for untagged images.
  retention_policy_in_days = var.retention_policy_days

  # System-assigned identity opens the door to future RBAC-based pull.
  managed_identities = {
    system_assigned = true
  }

  # Inline diagnostic settings (no-op when log_analytics_workspace_id is null).
  diagnostic_settings = var.log_analytics_workspace_id != null ? {
    to_law = {
      name                  = "${var.name}-diag"
      workspace_resource_id = var.log_analytics_workspace_id
      log_groups            = ["allLogs"]
      metric_categories     = ["AllMetrics"]
    }
  } : {}

  tags             = var.tags
  enable_telemetry = var.enable_telemetry
}

# ---------------------------------------------------------------------------
# Image import — server-side ACR importImage, one action per image.
# Equivalent to `az acr import`, but driven by Terraform so the registry is
# populated within `apply` (the consuming stack depends_on this module, so the
# Container Apps never start before their images exist). mode=Force makes the
# import idempotent and keeps the tag in sync with the pinned version on re-apply.
# ---------------------------------------------------------------------------
resource "azapi_resource_action" "import" {
  for_each = { for img in var.images : img.target => img }

  type        = "Microsoft.ContainerRegistry/registries@2023-11-01-preview"
  resource_id = module.container_registry.resource_id
  action      = "importImage"
  method      = "POST"

  body = {
    source = {
      registryUri = each.value.source_registry
      sourceImage = each.value.source_image
    }
    targetTags = [each.value.target]
    mode       = "Force"
  }
}
