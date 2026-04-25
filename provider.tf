terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
variable "location_primary" {
  default = "westus2"
}

variable "location_secondary" {
  default = "canadaeast"
}

variable "resource_group_name" {
  type    = string
  default = "mysql-multiregion-rg"
}

variable "db_username" {
  type    = string
  default = "mysqladmin"
}

variable "db_password" {
  type      = string
  sensitive = true
}
