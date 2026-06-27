variable "name" {
  type        = string
  description = "PostgreSQL Flexible Server name (globally unique, lowercase)."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create the server in."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "private_endpoints_subnet_id" {
  type        = string
  description = "Subnet ID for the PostgreSQL private endpoint."
}

variable "postgres_version" {
  type        = string
  description = "PostgreSQL major version."
  default     = "18"
}

variable "administrator_login" {
  type        = string
  description = "Administrator login name."
  default     = "gsadmin"
}

variable "sku_name" {
  type        = string
  description = "Flexible Server SKU (tier_Name). e.g. B_Standard_B1ms (dev), GP_Standard_D2ds_v5 (prod)."
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  type        = number
  description = "Storage in MB."
  default     = 32768
}

variable "config_database_name" {
  type        = string
  description = "Database name for the GeoServer Cloud pgconfig catalog backend."
  default     = "geoserver_config"
}

variable "data_database_name" {
  type        = string
  description = "Database name for PostGIS geospatial data."
  default     = "geodata"
}

variable "azure_extensions" {
  type        = string
  description = "Comma-separated azure.extensions allowlist enabled on the server."
  default     = "POSTGIS,POSTGIS_RASTER,FUZZYSTRMATCH,POSTGIS_TIGER_GEOCODER,UUID-OSSP"
}

variable "enable_high_availability" {
  type        = bool
  description = "Enable zone-redundant high availability (recommended for prod)."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply (use the naming module's common_tags)."
}

variable "key_vault_name" {
  type        = string
  description = "Name of the Key Vault to write the postgres-password secret into."
}

variable "key_vault_id" {
  type        = string
  description = "Resource ID of the Key Vault. Used as a trigger to ensure KV (and its DNS wait) is ready before the secret write."
}

variable "scripts_dir" {
  type        = string
  description = "Absolute path to the scripts directory containing wait-for-dns-zone.sh. Set to empty string to skip the DNS wait."
  default     = ""
}

variable "private_endpoint_dns_wait" {
  description = "Timeout and poll interval for the policy-managed DNS zone group wait."
  type = object({
    timeout       = optional(string, "12m")
    poll_interval = optional(string, "30s")
  })
  default = {}
}
