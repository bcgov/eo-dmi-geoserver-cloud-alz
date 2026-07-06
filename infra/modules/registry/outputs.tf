output "id" {
  description = "Resource ID of the container registry."
  value       = module.container_registry.resource_id
}

output "name" {
  description = "Container registry name."
  value       = module.container_registry.name
}

output "login_server" {
  description = "ACR login server (e.g. myregistry.azurecr.io)."
  value       = module.container_registry.resource.login_server
}

output "admin_username" {
  description = "ACR admin username."
  value       = module.container_registry.resource.admin_username
  sensitive   = true
}

output "admin_password" {
  description = "ACR admin password."
  value       = module.container_registry.resource.admin_password
  sensitive   = true
}

output "imported_images" {
  description = "Target repo:tag of every image imported into the registry by Terraform."
  # Referencing the import actions makes consumers that read this output wait
  # until every image has landed in the registry.
  value = [for k, _ in azapi_resource_action.import : k]
}
