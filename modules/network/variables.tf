variable "vnet_name" {
  type        = string
  description = "Name of the platform-provided spoke VNet."
}

variable "vnet_resource_group_name" {
  type        = string
  description = "Resource group that contains the VNet (the locked *-networking RG)."
}

variable "private_endpoints_subnet_name" {
  type        = string
  description = "Name of the pre-existing private endpoints subnet to reuse."
}

variable "aca_subnet_cidr" {
  type        = string
  description = "CIDR for the ACA subnet to create (delegated to Microsoft.App/environments, minimum /27). Must fall within the spoke VNet address space and must not overlap existing subnets."

  validation {
    condition     = can(cidrhost(var.aca_subnet_cidr, 0))
    error_message = "aca_subnet_cidr must be a valid CIDR (e.g. 10.46.10.32/27)."
  }
}

variable "location" {
  type        = string
  description = "Azure region for the NSG resource."
}

variable "name_prefix" {
  type        = string
  description = "Resource name prefix (e.g. geoserver-dev)."
}

variable "common_tags" {
  type        = map(string)
  description = "Tags applied to all resources created by this module."
  default     = {}
}
