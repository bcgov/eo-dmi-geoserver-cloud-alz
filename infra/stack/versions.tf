terraform {
  required_version = ">= 1.15.8" # floor matches mise.toml [tools].terraform
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81" # 5.x blocked: AVM registry module requires azurerm < 5.0.0
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    # Server-side ACR importImage (see modules/registry) — sources the GeoServer
    # Cloud images into the registry during apply, no Docker / az CLI needed.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
  }
}
