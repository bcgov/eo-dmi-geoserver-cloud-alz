# ---------------------------------------------------------------------------
# General — set via TF_VAR_* in each GitHub Environment
# ---------------------------------------------------------------------------
variable "environment" {
  type        = string
  description = "Deployment environment (dev | test | prod). Drives naming and tagging."

  validation {
    condition     = contains(["dev", "test", "prod", "tools"], var.environment)
    error_message = "environment must be dev, test, prod, or tools."
  }
}

variable "project" {
  type        = string
  description = "Project slug used as the resource name prefix."
  default     = "geoserver"
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "canadacentral"
}

variable "resource_group_name" {
  type        = string
  description = "Workload resource group to create (NOT the locked networking RG)."
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------
variable "ministry_name" {
  type        = string
  description = "Ministry name."
  default     = "WLRS"
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags merged on top of mandatory ALZ tags."
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking (platform-provided; consumed via data sources, never modified)
# ---------------------------------------------------------------------------
variable "vnet_name" {
  type        = string
  description = "Name of the platform-provided spoke VNet."
}

variable "vnet_resource_group_name" {
  type        = string
  description = "Resource group containing the VNet (the locked *-networking RG)."
}

variable "aca_subnet_cidr" {
  type        = string
  description = "CIDR for the ACA subnet to create (delegated to Microsoft.App/environments, minimum /27). Must be a free range in the spoke VNet address space."

  validation {
    condition     = can(cidrhost(var.aca_subnet_cidr, 0))
    error_message = "aca_subnet_cidr must be valid CIDR notation (e.g. 10.46.10.32/27)."
  }
}

variable "private_endpoints_subnet_name" {
  type        = string
  description = "Subnet used for private endpoints."
}


variable "key_vault_public_network_access_enabled" {
  type        = bool
  description = "Expose the Key Vault data plane publicly. Set true only for bootstrap applies from a hosted runner; harden to false once a VNet-attached runner is in place."
  default     = false
}

variable "key_vault_network_default_action" {
  type        = string
  description = "Default Key Vault network ACL action."
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.key_vault_network_default_action)
    error_message = "key_vault_network_default_action must be Allow or Deny."
  }
}

# ---------------------------------------------------------------------------
# Resource names — globally-unique names must be set explicitly.
# Non-unique names default to <project>-<environment> patterns via locals.
# ---------------------------------------------------------------------------
variable "acr_name" {
  type        = string
  description = "Container registry name (alphanumeric, globally unique, 5-50 chars)."
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault name (3-24 chars, globally unique)."
}

variable "postgres_server_name" {
  type        = string
  description = "PostgreSQL Flexible Server name (lowercase, globally unique)."
}

variable "log_analytics_name" {
  type        = string
  description = "Log Analytics workspace name. Defaults to log-<project>-<environment>."
  default     = null
}

variable "container_app_environment_name" {
  type        = string
  description = "Container Apps environment name. Defaults to cae-<project>-<environment>."
  default     = null
}

variable "uami_name" {
  type        = string
  description = "User-assigned managed identity name. Defaults to id-<project>-<environment>."
  default     = null
}

# ---------------------------------------------------------------------------
# Sizing / runtime — sensible defaults; override per environment via GitHub vars
# ---------------------------------------------------------------------------
variable "zone_redundancy_enabled" {
  type        = bool
  description = "Enable zone redundancy for the Container Apps environment."
  default     = false
}

variable "postgres_version" {
  type        = string
  description = "PostgreSQL major version."
  default     = "18"
}

variable "postgres_sku_name" {
  type        = string
  description = "PostgreSQL Flexible Server SKU."
  default     = "B_Standard_B1ms"
}

variable "postgres_enable_high_availability" {
  type        = bool
  description = "Enable zone-redundant HA for PostgreSQL."
  default     = false
}

variable "service_cpu" {
  type        = number
  description = "vCPU per GeoServer service replica."
  default     = 1.0
}

variable "service_memory" {
  type        = string
  description = "Memory per GeoServer service replica."
  default     = "2Gi"
}

variable "service_min_replicas" {
  type        = number
  description = "Minimum replicas per GeoServer service. Set to 0 to enable scale-to-zero."
  default     = 0
}

variable "service_max_replicas" {
  type        = number
  description = "Autoscale ceiling per GeoServer service."
  default     = 2
}

# ---------------------------------------------------------------------------
# GeoServer Cloud application versions
# ---------------------------------------------------------------------------
variable "gs_cloud_version" {
  type        = string
  description = "GeoServer Cloud image tag (pin explicitly)."
}

variable "spring_profiles_active" {
  type        = string
  description = "Spring profiles for standalone + pgconfig + acl topology."
  # environment-admin-auth: reads GEOSERVER_ADMIN_USERNAME/PASSWORD env vars to set the
  # GeoServer web-admin credentials at startup — the only reliable way to set a known
  # admin password across all replicas without touching the ephemeral data directory.
  default = "standalone,pgconfig,acl,environment-admin-auth"
}

variable "reset_pgconfig_schema" {
  type        = bool
  description = <<-EOT
    When true, the init job DROPs the pgconfig catalog schema before the GeoServer
    services (re)start, forcing a clean re-initialization. Use only for a catalog
    backend major-version migration (e.g. GeoServer 2.24 -> 3.0). DESTRUCTIVE: wipes
    all GeoServer catalog configuration (workspaces, stores, layers, styles). Keep
    false in normal operation.
  EOT
  default     = false
}

variable "acl_version" {
  type        = string
  description = "GeoServer ACL image tag."
  default     = "3.0.0"
}

variable "rabbitmq_image_tag" {
  type        = string
  description = "RabbitMQ image tag (with management plugin)."
  default     = "3-management"
}

variable "rabbitmq_user" {
  type        = string
  description = "RabbitMQ default username."
  default     = "geoserver"
}

variable "extra_service_env" {
  type        = map(string)
  description = "Extra plain env vars applied to every GeoServer service."
  default     = {}
}

# ---------------------------------------------------------------------------
# Node OIDC proxy (App Service)
# ---------------------------------------------------------------------------
variable "app_service_subnet_cidr" {
  type        = string
  description = "CIDR for the App Service VNet-integration subnet (/28 minimum, must be free in the spoke VNet)."
  default     = "10.46.10.144/28"
}

variable "proxy_app_service_name" {
  type        = string
  description = "Globally-unique App Service name for the Node OIDC proxy (becomes <name>.azurewebsites.net)."
}

variable "proxy_sku" {
  type        = string
  description = "App Service Plan SKU. Minimum B1 for VNet integration; B2 recommended for headroom."
  default     = "B2"
}

variable "proxy_image_tag" {
  type        = string
  description = "Tag for the node-oidc-proxy image built into ACR."
  default     = "latest"
}

variable "oidc_issuer" {
  type        = string
  description = "OIDC issuer URL (Keycloak realm endpoint)."
  default     = "https://test.loginproxy.gov.bc.ca/auth/realms/standard"
}

variable "oidc_client_id" {
  type        = string
  description = "Keycloak client ID for the OIDC proxy."
}

# ---------------------------------------------------------------------------
# Private endpoint DNS wait (BC Gov platform policy registers zone groups async)
# ---------------------------------------------------------------------------
variable "scripts_dir" {
  type        = string
  description = "Absolute path to the scripts directory containing wait-for-dns-zone.sh. Set to empty string to skip the DNS wait (e.g. when public_network_access_enabled = true)."
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
