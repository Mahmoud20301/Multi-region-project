terraform {
  backend "azurerm" {
    resource_group_name  = "mahmoud-tf-state-rg"
    storage_account_name = "tfstatemahmoud12345"
    container_name       = "tfstate"
    key                  = "aks-prod.tfstate"
  }
}