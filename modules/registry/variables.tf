variable "name" {
  type        = string
  description = "Container registry name (alphanumeric, globally unique, 5-50 chars)."

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.name))
    error_message = "Container registry name must be 5-50 alphanumeric characters (no hyphens)."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create the registry in."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "sku" {
  type        = string
  description = "ACR SKU. Standard is accepted in the BC Gov ALZ when no private endpoint is used."
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be one of: Basic, Standard, Premium."
  }
}

variable "admin_enabled" {
  type        = bool
  description = "Enable the ACR admin user (username/password auth for Container Apps pull)."
  default     = true
}

variable "retention_policy_days" {
  type        = number
  description = "Days to retain untagged manifests before garbage collection (0 = disabled)."
  default     = 7
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Resource ID of the Log Analytics workspace for diagnostic settings. Null disables diagnostics."
  default     = null
}

variable "enable_telemetry" {
  type        = bool
  description = "Send AVM telemetry to Microsoft. Keep false for BC Gov ALZ."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply (use the naming module's common_tags)."
}

variable "images" {
  type = list(object({
    source_registry = string # e.g. "docker.io"
    source_image    = string # repository + tag, e.g. "geoservercloud/geoserver-cloud-wms:3.0.0"
    target          = string # target repo + tag in this ACR, e.g. "geoserver-cloud-wms:3.0.0"
  }))
  description = <<-EOT
    Images to import into the registry via the server-side ACR importImage
    action (no Docker daemon, no az CLI). Each entry is re-imported with
    mode=Force on every apply, keeping ACR in sync with the pinned versions.
    Leave empty to skip import (e.g. when images are pushed by another process).
  EOT
  default     = []

  validation {
    condition     = length(distinct([for i in var.images : i.target])) == length(var.images)
    error_message = "Each images[].target must be unique."
  }
}
