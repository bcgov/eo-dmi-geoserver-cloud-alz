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

# --- Durable storage (Azure File share for /var/lib/rabbitmq) -----------------

variable "storage_account_name" {
  type        = string
  description = "Storage account that hosts the Azure File share for RabbitMQ's persistent data dir (created in the stack)."
}

variable "file_share_name" {
  type        = string
  description = "Azure File share name mounted at /var/lib/rabbitmq."
  default     = "rabbitmq-data"
}

variable "storage_account_access_key" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Access key for the storage account, used by the Container Apps Environment
    storage registration. NOTE: azurerm_container_app_environment_storage requires
    the key inline, so it lands in Terraform state. Acceptable for the POC (the
    tfstate backend is VNet-locked); for prod, prefer NFS Azure Files (no key) or
    move RabbitMQ to AKS / Azure Service Bus.
  EOT
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
  description = "Minimum replicas. POC default 0 (scale-to-zero). TODO: set to 1 before live demos / prod — TCP transport has no built-in scale trigger, so 0 can leave the bus cold."
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
