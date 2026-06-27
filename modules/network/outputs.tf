output "vnet_id" {
  description = "Resource ID of the spoke VNet."
  value       = data.azurerm_virtual_network.this.id
}

output "aca_subnet_id" {
  description = "Resource ID of the ACA subnet (Microsoft.App/environments delegation)."
  value       = azapi_resource.aca_subnet.id
}

output "private_endpoints_subnet_id" {
  description = "Resource ID of the pre-existing private-endpoints subnet."
  value       = data.azurerm_subnet.private_endpoints.id
}
