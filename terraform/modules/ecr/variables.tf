variable "repositories" {
  description = "Repository names to create (e.g. [\"demo-api\"])."
  type        = list(string)

  validation {
    condition     = length(var.repositories) > 0 && alltrue([for r in var.repositories : can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", r))])
    error_message = "repositories must be non-empty and contain valid ECR repository names."
  }
}

variable "keep_tagged_images" {
  description = "Number of release-tagged images to retain per repository."
  type        = number
  default     = 50

  validation {
    condition     = var.keep_tagged_images >= 5
    error_message = "Keep at least 5 tagged images so rollbacks remain possible."
  }
}

variable "untagged_expiry_days" {
  description = "Days after which untagged images (build cache, superseded pushes) expire."
  type        = number
  default     = 7
}

variable "pull_principal_arns" {
  description = "Additional IAM principals (e.g. other accounts' node roles) allowed to pull."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
