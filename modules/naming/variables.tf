variable "project" {
  type        = string
  description = "Short project slug used as the resource name prefix."
  default     = "geoserver"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, test, or prod)."
  validation {
    condition     = contains(["dev", "test", "prod", "tools"], var.environment)
    error_message = "environment must be one of: dev, test, prod, tools."
  }
}

variable "ministry_name" {
  type        = string
  description = "Ministry name (mandatory ALZ tag)."
  default     = "WLRS"
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags merged on top of the mandatory tag set."
  default     = {}
}
