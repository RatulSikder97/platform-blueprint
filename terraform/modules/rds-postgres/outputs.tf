output "endpoint" {
  description = "Writer endpoint host name."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "instance_resource_id" {
  description = "DbiResourceId, needed for rds-db:connect IAM policies."
  value       = aws_db_instance.this.resource_id
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN holding the RDS-managed master credentials (consume via External Secrets)."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group attached to the instance."
  value       = aws_security_group.this.id
}

output "kms_key_arn" {
  description = "CMK encrypting storage, snapshots and the master secret."
  value       = aws_kms_key.this.arn
}
