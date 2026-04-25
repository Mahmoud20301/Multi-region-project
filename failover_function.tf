# ================= AUTOMATION ACCOUNT =================
# Free tier: 500 min/month job runtime, Python 3 runbooks, webhook triggers
# Works on Azure for Students subscriptions (no App Service quota needed)
# NOTE: Student subs only allow Automation in: eastus, eastus2, westus, northeurope, southeastasia, japanwest
locals {
  automation_location = "eastus"
}

resource "azurerm_automation_account" "failover" {
  name                = "aa-failover-wordpress"
  location            = local.automation_location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Free"

  identity {
    type = "SystemAssigned"
  }
}

# ================= PYTHON RUNBOOK =================
resource "azurerm_automation_runbook" "failover" {
  name                    = "failover-runbook"
  location                = local.automation_location
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.failover.name
  log_verbose             = false
  log_progress            = true
  runbook_type            = "Python3"
  description             = "Detects Traffic Manager failover, promotes MySQL replica, scales secondary AKS to 4 replicas"

  content = templatefile("${path.module}/failover_runbook.py", {
    subscription_id   = data.azurerm_client_config.current.subscription_id
    resource_group    = azurerm_resource_group.rg.name
    mysql_replica     = azurerm_mysql_flexible_server.replica.name
    aks_secondary     = azurerm_kubernetes_cluster.secondary_cluster.name
    la_workspace_id   = azurerm_log_analytics_workspace.monitor.workspace_id
  })
}

# ================= WEBHOOK (used by Action Group) =================
resource "azurerm_automation_webhook" "failover" {
  name                    = "failover-webhook"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.failover.name
  expiry_time             = "2030-01-01T00:00:00Z"
  enabled                 = true
  runbook_name            = azurerm_automation_runbook.failover.name
  parameters              = {}
}

# ================= CURRENT SUBSCRIPTION DATA =================
data "azurerm_client_config" "current" {}

# ================= RBAC: MySQL Contributor on replica =================
resource "azurerm_role_assignment" "fn_mysql_replica" {
  scope                = azurerm_mysql_flexible_server.replica.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.failover.identity[0].principal_id
}

# ================= RBAC: AKS Cluster Admin – secondary =================
resource "azurerm_role_assignment" "fn_aks_secondary" {
  scope                = azurerm_kubernetes_cluster.secondary_cluster.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = azurerm_automation_account.failover.identity[0].principal_id
}

# ================= RBAC: AKS Cluster Admin – primary =================
resource "azurerm_role_assignment" "fn_aks_primary" {
  scope                = azurerm_kubernetes_cluster.production_cluster.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = azurerm_automation_account.failover.identity[0].principal_id
}

# ================= RBAC: Needed for AKS runCommand =================
resource "azurerm_role_assignment" "aks_runcommand" {
  scope                = azurerm_kubernetes_cluster.secondary_cluster.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.failover.identity[0].principal_id
}

# ================= RBAC: Log Analytics Reader =================
resource "azurerm_role_assignment" "fn_log_analytics" {
  scope                = azurerm_log_analytics_workspace.monitor.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_automation_account.failover.identity[0].principal_id
}

# ================= OUTPUT: Webhook URL =================
output "failover_webhook_url" {
  description = "Webhook URL for the failover runbook (used in Action Group)"
  value       = azurerm_automation_webhook.failover.uri
  sensitive   = true  # Contains auth token – use: terraform output failover_webhook_url
}
