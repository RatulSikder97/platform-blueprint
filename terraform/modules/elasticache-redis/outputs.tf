output "primary_endpoint" {
  description = "Primary (read/write) endpoint."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Reader endpoint (load-balanced across replicas)."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "Cache port."
  value       = local.port
}

output "auth_secret_arn" {
  description = "Secrets Manager ARN with host/port/password (consume via External Secrets)."
  value       = aws_secretsmanager_secret.auth.arn
}

output "security_group_id" {
  description = "Security group attached to the cache nodes."
  value       = aws_security_group.this.id
}
