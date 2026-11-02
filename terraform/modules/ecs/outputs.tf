output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "database_url_secret_arn" {
  value = aws_secretsmanager_secret.database_url.arn
}
