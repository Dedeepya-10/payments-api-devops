output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "database_url_secret_arn" {
  value = module.ecs.database_url_secret_arn
}
