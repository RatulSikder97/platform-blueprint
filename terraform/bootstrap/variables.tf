variable "region" {
  description = "Region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name."
  }
}

variable "create_dynamodb_lock_table" {
  description = "Create a DynamoDB lock table for Terraform < 1.10 clients. Newer clients use S3-native locking (use_lockfile = true)."
  type        = bool
  default     = false
}
