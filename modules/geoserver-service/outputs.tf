output "id" {
  description = "Resource ID of the Container App."
  value       = azurerm_container_app.this.id
}

output "name" {
  description = "Container App name."
  value       = azurerm_container_app.this.name
}

output "fqdn" {
  description = "Ingress FQDN of the app (internal to the environment's VNet)."
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
}

output "latest_revision_fqdn" {
  description = "FQDN of the latest revision."
  value       = try(azurerm_container_app.this.latest_revision_fqdn, null)
}
