variable "name" {
  description = "Name prefix (usually the cluster name)."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster whose Prometheus agent remote-writes to AMP (via Pod Identity)."
  type        = string
}

variable "enable_managed_prometheus" {
  description = "Create an Amazon Managed Service for Prometheus workspace and a remote-write role. When false, in-cluster kube-prometheus-stack keeps metrics locally."
  type        = bool
  default     = false
}

variable "enable_managed_grafana" {
  description = "Create an Amazon Managed Grafana workspace (requires IAM Identity Center in the account)."
  type        = bool
  default     = false
}

variable "prometheus_namespace" {
  description = "Namespace of the in-cluster Prometheus that remote-writes to AMP."
  type        = string
  default     = "monitoring"
}

variable "prometheus_service_account" {
  description = "Service account of the in-cluster Prometheus."
  type        = string
  default     = "kube-prometheus-stack-prometheus"
}

variable "log_retention_days" {
  description = "Retention for AMP workspace logs."
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = "Optional e-mail subscribed to the platform alerts SNS topic. Empty skips the subscription."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid e-mail address."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
