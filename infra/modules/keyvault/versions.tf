terraform {
  required_version = ">= 1.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
  }
}
