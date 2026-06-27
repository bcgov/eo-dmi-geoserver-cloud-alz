variable "name" {
  type        = string
  description = "RabbitMQ Container App name."
  default     = "rabbitmq"
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
  description = "RabbitMQ image reference (e.g. myacr.azurecr.io/rabbitmq:3-management)."
}

variable "registry_server" {
  type        = string
  description = "ACR login server."
}

variable "registry_username" {
  type        = string
  description = "ACR admin username."
}

variable "acr_password_secret_id" {
  type        = string
  description = "Key Vault secret ID holding the ACR admin password."
}

variable "rabbitmq_user" {
  type        = string
  description = "RabbitMQ default username."
  default     = "geoserver"
}

variable "rabbitmq_password_secret_id" {
  type        = string
  description = "Key Vault secret ID holding the RabbitMQ password."
}

variable "cpu" {
  type        = number
  description = "vCPU for the RabbitMQ container."
  default     = 0.5
}

variable "memory" {
  type        = string
  description = "Memory for the RabbitMQ container."
  default     = "1Gi"
}

variable "min_replicas" {
  type        = number
  description = "Minimum replicas. Set to 0 for scale-to-zero (note: TCP transport has no built-in trigger, so 0 means manual scale-up is required)."
  default     = 0
}

variable "external_ingress" {
  type        = bool
  description = "Expose RabbitMQ on the environment's internal load balancer (VNet-reachable). Set true for debugging; false for production."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply (use the naming module's common_tags)."
}
