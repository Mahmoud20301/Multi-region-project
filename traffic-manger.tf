# ================= TRAFFIC MANAGER PROFILE =================
resource "azurerm_traffic_manager_profile" "tm" {
  name                = "tm-wordpress-mahmoud"
  resource_group_name = azurerm_resource_group.rg.name
  traffic_routing_method = "Priority"

  dns_config {
    relative_name = "mahmoud-wp-tm"
    ttl           = 30
  }

  monitor_config {
    protocol                     = "HTTP"
    port                         = 80
    path                         = "/"
    interval_in_seconds         = 30
    timeout_in_seconds          = 10
    tolerated_number_of_failures = 3
  }
}

# ================= PRIMARY ENDPOINT =================
resource "azurerm_traffic_manager_external_endpoint" "primary" {
  name                = "primary-endpoint"
  profile_id          = azurerm_traffic_manager_profile.tm.id
  target              = "20.252.89.14"   # PRIMARY AKS EXTERNAL IP
  enabled     = true
  priority            = 1
  weight              = 1
}

# ================= SECONDARY ENDPOINT =================
resource "azurerm_traffic_manager_external_endpoint" "secondary" {
  name                = "secondary-endpoint"
  profile_id          = azurerm_traffic_manager_profile.tm.id
  target              = "4.239.100.97"   # SECONDARY AKS EXTERNAL IP
  enabled     = true
  priority            = 2
  weight              = 1
}