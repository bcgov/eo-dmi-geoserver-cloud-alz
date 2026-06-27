output "id" {
  description = "Resource ID of the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  description = "PostgreSQL server name."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Fully qualified domain name of the server (resolves to the private endpoint)."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "administrator_login" {
  description = "Administrator login name."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}

output "config_database_name" {
  description = "Name of the pgconfig catalog database."
  value       = azurerm_postgresql_flexible_server_database.config.name
}

output "data_database_name" {
  description = "Name of the PostGIS data database."
  value       = azurerm_postgresql_flexible_server_database.data.name
}
