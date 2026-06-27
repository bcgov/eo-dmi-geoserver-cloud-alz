output "id" {
  description = "Resource ID of the RabbitMQ Container App."
  value       = azurerm_container_app.rabbitmq.id
}

output "name" {
  description = "RabbitMQ Container App name (used as the AMQP host within the environment)."
  value       = azurerm_container_app.rabbitmq.name
}

output "fqdn" {
  description = "Internal ingress FQDN of RabbitMQ."
  value       = try(azurerm_container_app.rabbitmq.ingress[0].fqdn, null)
}
