output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.production_cluster.name
}

output "primary_db_host" {
  value = azurerm_mysql_flexible_server.primary.fqdn
}

output "replica_db_host" {
  value = azurerm_mysql_flexible_server.replica.fqdn
}