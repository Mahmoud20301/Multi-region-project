
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location_primary
}


resource "azurerm_virtual_network" "vnet_primary" {
  name                = "vnet-primary"
  location            = var.location_primary
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/8"]
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet_primary.name
  address_prefixes     = ["10.10.0.0/16"]
}


resource "azurerm_subnet" "mysql_subnet" {
  name                 = "mysql-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet_primary.name
  address_prefixes     = ["10.20.0.0/24"]

  delegation {
    name = "mysql-delegation"

    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}


resource "azurerm_private_dns_zone" "mysql_dns" {
  name                = "privatelink.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql_dns_link" {
  name                  = "mysql-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.mysql_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet_primary.id
}


resource "azurerm_kubernetes_cluster"  "production_cluster"{
  name                = "production-cluster"
  location            = var.location_primary
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "prodaks"

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                = "agentpool"
    vm_size             = "Standard_D2pds_v5"
    vnet_subnet_id      = azurerm_subnet.aks_subnet.id
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 3
  }

  network_profile {
    network_plugin = "azure"
  }

  oidc_issuer_enabled = true

  depends_on = [
    azurerm_subnet.aks_subnet
  ]
}


resource "azurerm_mysql_flexible_server" "primary" {
  name                   = "mysql-primary-mahmoud123"
  location               = var.location_primary
  resource_group_name    = azurerm_resource_group.rg.name

  administrator_login    = var.db_username
  administrator_password = var.db_password

  sku_name              = "MO_Standard_E2ds_v4"
  version               = "8.0.21"
  backup_retention_days = 7

  delegated_subnet_id = azurerm_subnet.mysql_subnet.id
  private_dns_zone_id = azurerm_private_dns_zone.mysql_dns.id

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.mysql_dns_link
  ]
}


resource "time_sleep" "wait_primary" {
  depends_on      = [azurerm_mysql_flexible_server.primary]
  create_duration = "180s"
}


resource "azurerm_mysql_flexible_server" "replica" {
  name                = "mysql-secondary-mahmoud123"
  location            = var.location_secondary
  resource_group_name = azurerm_resource_group.rg.name

  create_mode      = "Replica"
  source_server_id = azurerm_mysql_flexible_server.primary.id
  sku_name         = "MO_Standard_E2ds_v4"

  depends_on = [
    time_sleep.wait_primary
  ]
}

resource "azurerm_mysql_flexible_database" "wordpress_db" {
  name                = "wordpressdb"
  resource_group_name = azurerm_resource_group.rg.name
  server_name         = azurerm_mysql_flexible_server.primary.name

  charset   = "utf8mb4"
  collation = "utf8mb4_unicode_ci"
}

resource "azurerm_mysql_flexible_server_configuration" "ssl_off" {
  name                = "require_secure_transport"
  resource_group_name = azurerm_resource_group.rg.name
  server_name         = azurerm_mysql_flexible_server.primary.name
  value               = "OFF"
}