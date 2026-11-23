output "state_bucket" {
  description = "Bucket to reference from envs/*/backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "DynamoDB lock table (null unless create_dynamodb_lock_table)."
  value       = try(aws_dynamodb_table.lock[0].name, null)
}
