terraform {
  required_version = ">= 1.15"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.79"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Server-side ACR importImage (see modules/registry) — sources the GeoServer
    # Cloud images into the registry during apply, no Docker / az CLI needed.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}
