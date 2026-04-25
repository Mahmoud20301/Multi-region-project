
resource "azurerm_log_analytics_workspace" "monitor" {
  name                = "la-wordpress-monitor"
  location            = var.location_primary
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}


resource "azurerm_monitor_action_group" "main" {
  name                = "wordpress-alerts"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "wpalert"

  email_receiver {
    name          = "admin"
    email_address = "modymohamed1121@gmail.com"
  }

  
  webhook_receiver {
    name                    = "failover-automation-webhook"
    service_uri             = azurerm_automation_webhook.failover.uri
    use_common_alert_schema = true
  }
}


resource "azurerm_monitor_diagnostic_setting" "aks_primary" {
  name                       = "aks-primary-diagnostics"
  target_resource_id         = azurerm_kubernetes_cluster.production_cluster.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.monitor.id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}


resource "azurerm_monitor_diagnostic_setting" "aks_secondary" {
  name                       = "aks-secondary-diagnostics"
  target_resource_id         = azurerm_kubernetes_cluster.secondary_cluster.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.monitor.id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}


resource "azurerm_monitor_diagnostic_setting" "tm_diagnostics" {
  name                       = "tm-diagnostics"
  target_resource_id         = azurerm_traffic_manager_profile.tm.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.monitor.id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}


resource "azurerm_monitor_scheduled_query_rules_alert" "traffic_manager_failover" {
  name                = "traffic-manager-failover-alert"
  location            = var.location_primary
  resource_group_name = azurerm_resource_group.rg.name

  data_source_id = azurerm_log_analytics_workspace.monitor.id

  description = "Traffic Manager endpoint failure detected"
  severity    = 1
  frequency   = 5
  time_window = 10

  query = <<QUERY
AzureMetrics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where MetricName == "DipAvailability"
| summarize avg(Average) by Resource
| where avg_Average < 100
QUERY

  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }

  action {
    action_group = [azurerm_monitor_action_group.main.id]
  }
}