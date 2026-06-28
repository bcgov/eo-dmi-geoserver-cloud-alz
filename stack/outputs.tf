output "resource_group_name" {
  description = "Workload resource group name."
  value       = azurerm_resource_group.this.name
}

output "acr_name" {
  description = "Container registry name. Images are imported into it by Terraform (modules/registry)."
  value       = module.registry.name
}

output "acr_login_server" {
  description = "Container registry login server."
  value       = module.registry.login_server
}

output "imported_images" {
  description = "Image tags Terraform imported into the registry."
  value       = module.registry.imported_images
}

output "container_app_environment_id" {
  description = "Container Apps environment resource ID."
  value       = module.container_app_environment.id
}

output "environment_default_domain" {
  description = "Container Apps environment default domain."
  value       = module.container_app_environment.default_domain
}

output "environment_static_ip" {
  description = "Internal static IP of the environment load balancer."
  value       = module.container_app_environment.static_ip_address
}

output "gateway_fqdn" {
  description = "Internal FQDN of the GeoServer gateway (entry point over the VNet)."
  value       = try(module.service["gateway"].fqdn, null)
}

output "postgres_fqdn" {
  description = "PostgreSQL server FQDN (resolves to the private endpoint)."
  value       = module.postgres.fqdn
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = module.keyvault.uri
}

output "proxy_url" {
  description = "Public URL of the Node OIDC proxy (App Service entry point)."
  value       = "https://${azapi_resource.proxy.output.properties.defaultHostName}"
}

output "proxy_oidc_redirect_uri" {
  description = "Keycloak redirect URI — register this in the Keycloak client's Valid Redirect URIs."
  value       = "https://${azapi_resource.proxy.output.properties.defaultHostName}/auth/callback"
}
