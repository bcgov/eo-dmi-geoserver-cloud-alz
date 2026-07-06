# Authentication driven entirely by ARM_* env vars set in the GitHub Environment:
#   GHA   -> ARM_USE_OIDC=true + ARM_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID
#   local -> ARM_USE_CLI=true  (az login)
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

provider "random" {}

# Server-side ACR importImage — inherits the same OIDC context as azurerm.
provider "azapi" {}
