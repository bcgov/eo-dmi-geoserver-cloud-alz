variable "name" {
  type        = string
  description = "Container Apps environment name."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create the environment and identity in."
}

variable "location" {
  type        = string
  description = "Azure region."
}


variable "infrastructure_subnet_id" {
  type        = string
  description = "ID of the subnet delegated to Microsoft.App/environments (>= /27)."
}

variable "internal_load_balancer_enabled" {
  type        = bool
  description = "Use an internal load balancer only (no public ingress). Must be true for BC Gov ALZ."
  default     = true
}

variable "zone_redundancy_enabled" {
  type        = bool
  description = "Enable zone redundancy for the environment (recommended for prod)."
  default     = false
}

variable "mtls_enabled" {
  type        = bool
  description = "Enable mutual TLS peer authentication between Container Apps in this environment."
  default     = false
}

variable "workload_profiles" {
  description = "Additional dedicated compute workload profiles (Consumption is always included)."
  type = list(object({
    name                  = string
    workload_profile_type = string
    minimum_count         = optional(number)
    maximum_count         = optional(number)
  }))
  default = []
}

variable "enable_diagnostics" {
  type        = bool
  description = "Enable diagnostic settings forwarding console/system logs and metrics to the Log Analytics workspace."
  default     = false
}

variable "private_endpoints_subnet_id" {
  type        = string
  description = "ID of the private-endpoints subnet for the CAE private endpoint. Empty string disables PE creation."
  default     = ""
}

variable "uami_name" {
  type        = string
  description = "Name of the user-assigned managed identity shared by the apps."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply (use the naming module's common_tags)."
}
variable "log_analytics_workspace_customer_id" {
  description = "Log Analytics Workspace customer ID (GUID) for Container Apps Environment logs"
  type        = string
  nullable    = false
}

variable "log_analytics_workspace_key" {
  description = "Log Analytics Workspace primary shared key for Container Apps Environment logs"
  type        = string
  sensitive   = true
  nullable    = false
}
variable "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID for Container Apps Environment"
  type        = string
  nullable    = false
}
