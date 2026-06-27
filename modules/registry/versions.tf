terraform {
  required_version = ">= 1.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.38"
    }
    # azapi drives the server-side ACR importImage action (no Docker daemon, no
    # az CLI) so images are sourced into the registry by Terraform itself.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}
