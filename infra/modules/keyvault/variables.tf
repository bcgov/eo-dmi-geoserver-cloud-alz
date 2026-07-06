variable "name" {
  type        = string
  description = "Key Vault name (3-24 chars, globally unique)."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create the Key Vault in."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "tenant_id" {
  type        = string
  description = "Entra tenant ID for the Key Vault."
}

variable "private_endpoints_subnet_id" {
  type        = string
  description = "Subnet ID for the Key Vault private endpoint."
}

variable "reader_principal_ids" {
  type        = list(string)
  description = "Principal object IDs granted 'Key Vault Secrets User' (runtime readers, e.g. the ACA managed identity)."
  default     = []
}

variable "admin_principal_ids" {
  type        = list(string)
  description = "Principal object IDs granted 'Key Vault Secrets Officer' (e.g. the Terraform deploy identity that writes secrets)."
  default     = []
}

variable "purge_protection_enabled" {
  type        = bool
  description = "Enable Key Vault purge protection."
  default     = true
}

variable "soft_delete_retention_days" {
  type        = number
  description = "Soft-delete retention period in days."
  default     = 7
}

variable "public_network_access_enabled" {
  type        = bool
  description = "Allow public network access. Bootstrap default true; harden to false for production."
  default     = true
}

variable "network_default_action" {
  type        = string
  description = "Default network ACL action (Allow for bootstrap, Deny for hardened)."
  default     = "Allow"
  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be Allow or Deny."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply (use the naming module's common_tags)."
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
