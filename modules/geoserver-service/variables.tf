variable "name" {
  type        = string
  description = "Container App name (also the GeoServer Cloud service name, e.g. gateway, wms)."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create the Container App in."
}

variable "container_app_environment_id" {
  type        = string
  description = "Resource ID of the Container Apps environment."
}

variable "uami_id" {
  type        = string
  description = "Resource ID of the shared user-assigned managed identity."
}

variable "image" {
  type        = string
  description = "Fully qualified image reference, e.g. myacr.azurecr.io/geoserver-cloud-wms:1.9.0."
}

variable "registry_server" {
  type        = string
  description = "ACR login server (e.g. myacr.azurecr.io)."
}

variable "registry_username" {
  type        = string
  description = "ACR admin username."
}

variable "registry_password_secret_name" {
  type        = string
  description = "Name of the Container App secret holding the ACR admin password (must be present in var.secrets)."
  default     = "acr-password"
}

variable "secrets" {
  type = list(object({
    name                = string
    key_vault_secret_id = string
  }))
  description = "Key Vault-referenced secrets exposed to the app (must include the ACR password secret)."
  default     = []
}

variable "env" {
  type        = map(string)
  description = "Plain (non-secret) environment variables."
  default     = {}
}

variable "secret_env" {
  type = list(object({
    name        = string
    secret_name = string
  }))
  description = "Environment variables whose values come from named Container App secrets."
  default     = []
}

variable "external_ingress" {
  type        = bool
  description = "Expose on the environment's internal load balancer (true for the gateway only)."
  default     = false
}

variable "target_port" {
  type        = number
  description = "Container port the app listens on."
  default     = 8080
}

variable "transport" {
  type        = string
  description = "Ingress transport: auto, http, http2, or tcp."
  default     = "auto"
}

variable "allow_insecure_connections" {
  type        = bool
  description = "Allow plain HTTP to the ingress (internal service-to-service)."
  default     = false
}

variable "cpu" {
  type        = number
  description = "vCPU per replica. Valid Consumption combos: 0.25/0.5/0.75/1.0/1.25.../2.0 paired with memory."
  default     = 1.0
}

variable "memory" {
  type        = string
  description = "Memory per replica (e.g. 2Gi). Must pair with cpu per ACA rules (cpu:memory ~= 1:2)."
  default     = "2Gi"
}

variable "min_replicas" {
  type        = number
  description = "Minimum replica count."
  default     = 1
}

variable "max_replicas" {
  type        = number
  description = "Maximum replica count (autoscale ceiling)."
  default     = 2
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply (use the naming module's common_tags)."
}
