# ---------------------------------------------------------------------------
# Durable storage for the RabbitMQ broker data dir (/var/lib/rabbitmq).
#
# The rabbitmq module mounts an Azure File share so broker state (Mnesia DB,
# definitions, durable messages) survives container restarts. The share lives on
# a Standard storage account defined here.
#
# Reuse-or-create:
#   rabbitmq_create_storage_account = true  (default) → create a new account.
#   rabbitmq_create_storage_account = false           → reuse an existing account
#     named var.rabbitmq_storage_account_name in this resource group (e.g. one you
#     created out-of-band with `az storage account create`). The file share is
#     still created/managed by Terraform in whichever account is selected.
#
# Public network access is intentionally ON (default_action = Allow) so the
# Terraform runner and the ACA file mount reach the file endpoint without a
# private endpoint — this matches the agreed POC posture. The flags below mirror
# the working `az storage account create` command (Standard_LRS / StorageV2 /
# Hot / TLS1_2 / https-only / default-action Allow / bypass AzureServices /
# allow-blob-public-access false / enable-local-user false).
#
# TODO(before prod): lock this down with a private endpoint for the `file`
# sub-resource + privatelink.file.core.windows.net DNS (mirror modules/keyvault),
# and flip public_network_access_enabled = false.
# ---------------------------------------------------------------------------

variable "rabbitmq_storage_account_name" {
  type        = string
  description = "Storage account name for RabbitMQ's durable data share (3-24 lowercase alphanumerics, globally unique). Created when rabbitmq_create_storage_account = true, otherwise reused."
  default     = "stgeoservertoolsrmq"
}

variable "rabbitmq_create_storage_account" {
  type        = bool
  description = "Create a new storage account (true) or reuse an existing one named rabbitmq_storage_account_name in this RG (false)."
  default     = true
}

resource "azurerm_storage_account" "rabbitmq" {
  count = var.rabbitmq_create_storage_account ? 1 : 0

  name                            = var.rabbitmq_storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = true  # POC: reachable from the TF runner + ACA mount
  shared_access_key_enabled       = true  # required — ACA env storage authenticates with the access key
  allow_nested_items_to_be_public = false # = az --allow-blob-public-access false
  local_user_enabled              = false # = az --enable-local-user false
  tags                            = module.naming.common_tags

  network_rules {
    default_action = "Allow"           # = az --default-action Allow
    bypass         = ["AzureServices"] # = az --bypass AzureServices
  }
}

# Reuse path: resolve an existing account by name when not creating one.
data "azurerm_storage_account" "rabbitmq" {
  count               = var.rabbitmq_create_storage_account ? 0 : 1
  name                = var.rabbitmq_storage_account_name
  resource_group_name = azurerm_resource_group.this.name
}

locals {
  rabbitmq_storage_account_id   = var.rabbitmq_create_storage_account ? azurerm_storage_account.rabbitmq[0].id : data.azurerm_storage_account.rabbitmq[0].id
  rabbitmq_storage_account_name = var.rabbitmq_create_storage_account ? azurerm_storage_account.rabbitmq[0].name : data.azurerm_storage_account.rabbitmq[0].name
  rabbitmq_storage_account_key  = var.rabbitmq_create_storage_account ? azurerm_storage_account.rabbitmq[0].primary_access_key : data.azurerm_storage_account.rabbitmq[0].primary_access_key
}

# Durable share mounted at /var/lib/rabbitmq by the rabbitmq module.
resource "azurerm_storage_share" "rabbitmq" {
  name               = "rabbitmq-data"
  storage_account_id = local.rabbitmq_storage_account_id
  quota              = 16 # GiB — broker metadata + durable messages are small
}
