resource "kubernetes_secret_v1" "mysql_secret" {
  metadata {
    name = "mysql-secret"
  }

  data = {
    mysql-user     = var.db_username
    mysql-password = var.db_password
  }

  type = "Opaque"
}