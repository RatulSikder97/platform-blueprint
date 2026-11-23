output "alerts_topic_arn" {
  description = "SNS topic for CloudWatch alarms and Grafana notifications."
  value       = aws_sns_topic.alerts.arn
}

output "amp_workspace_id" {
  description = "AMP workspace ID (null when disabled)."
  value       = try(aws_prometheus_workspace.this[0].id, null)
}

output "amp_remote_write_url" {
  description = "Prometheus remoteWrite URL (null when disabled)."
  value       = try("${aws_prometheus_workspace.this[0].prometheus_endpoint}api/v1/remote_write", null)
}

output "amp_remote_write_role_arn" {
  description = "Role bound to the Prometheus service account via Pod Identity (null when disabled)."
  value       = try(aws_iam_role.remote_write[0].arn, null)
}

output "grafana_endpoint" {
  description = "Managed Grafana URL (null when disabled)."
  value       = try("https://${aws_grafana_workspace.this[0].endpoint}", null)
}
