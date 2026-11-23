variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "region must be a valid AWS region name."
  }
}

variable "allowed_account_ids" {
  description = "AWS account IDs this environment may be applied to (provider guard rail). Leave empty only for offline validation."
  type        = list(string)
  default     = null

  validation {
    condition     = var.allowed_account_ids == null ? true : alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must contain 12-digit AWS account IDs."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM principals (SSO admin role, CI deploy role) granted cluster-admin via EKS access entries."
  type        = list(string)
  default     = []
}

variable "alarm_email" {
  description = "Optional e-mail for platform alerts."
  type        = string
  default     = ""
  sensitive   = true
}
