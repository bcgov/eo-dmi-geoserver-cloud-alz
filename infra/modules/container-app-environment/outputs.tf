output "id" {
  description = "Resource ID of the Container Apps environment."
  value       = azurerm_container_app_environment.this.id
}

output "default_domain" {
  description = "Default domain of the environment (apps are reachable at <app>.<default_domain>)."
  value       = azurerm_container_app_environment.this.default_domain
}

output "static_ip_address" {
  description = "Internal static IP of the environment's load balancer."
  value       = azurerm_container_app_environment.this.static_ip_address
}

output "uami_id" {
  description = "Resource ID of the shared user-assigned managed identity."
  value       = azurerm_user_assigned_identity.apps.id
}

output "uami_principal_id" {
  description = "Principal (object) ID of the shared user-assigned managed identity."
  value       = azurerm_user_assigned_identity.apps.principal_id
}

output "uami_client_id" {
  description = "Client ID of the shared user-assigned managed identity."
  value       = azurerm_user_assigned_identity.apps.client_id
}
