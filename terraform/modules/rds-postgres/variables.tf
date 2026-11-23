variable "identifier" {
  description = "RDS instance identifier and name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,50}[a-z0-9]$", var.identifier))
    error_message = "identifier must be lowercase alphanumeric with hyphens, start with a letter and not end with a hyphen."
  }
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated database subnet IDs (at least two AZs)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "A DB subnet group needs subnets in at least two AZs."
  }
}

variable "allowed_security_groups" {
  description = "Security groups allowed to connect, keyed by a static label (e.g. { eks_nodes = sg-... }). Static keys keep for_each plannable when IDs are unknown until apply."
  type        = map(string)
  default     = {}
}

variable "engine_major_version" {
  description = "PostgreSQL major version. pgvector ships with RDS for PostgreSQL 15.2+; 16+ recommended for HNSW performance."
  type        = string
  default     = "17"

  validation {
    condition     = contains(["16", "17", "18"], var.engine_major_version)
    error_message = "engine_major_version must be 16, 17 or 18."
  }
}

variable "instance_class" {
  description = "Instance class. Graviton (db.*g) classes are ~10-20% cheaper for the same performance."
  type        = string
  default     = "db.t4g.medium"

  validation {
    condition     = can(regex("^db\\.", var.instance_class))
    error_message = "instance_class must start with db."
  }
}

variable "allocated_storage_gib" {
  description = "Initial gp3 storage."
  type        = number
  default     = 50

  validation {
    condition     = var.allocated_storage_gib >= 20 && var.allocated_storage_gib <= 65536
    error_message = "allocated_storage_gib must be between 20 and 65536."
  }
}

variable "max_allocated_storage_gib" {
  description = "Storage autoscaling ceiling. Must be >= allocated_storage_gib."
  type        = number
  default     = 200
}

variable "database_name" {
  description = "Initial database name."
  type        = string
  default     = "app"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be a valid PostgreSQL identifier."
  }
}

variable "master_username" {
  description = "Master username. The password is generated and rotated by RDS in Secrets Manager."
  type        = string
  default     = "platform_admin"
}

variable "multi_az" {
  description = "Synchronous standby in a second AZ."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Automated backup retention (enables PITR)."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35 (0 would disable backups)."
  }
}

variable "backup_window" {
  description = "Daily UTC backup window."
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Weekly UTC maintenance window (must not overlap the backup window)."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "deletion_protection" {
  description = "Block deletes at the API level."
  type        = bool
  default     = true
}

variable "performance_insights_retention_days" {
  description = "Performance Insights retention: 7 (free tier) or a multiple of 31."
  type        = number
  default     = 7
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds (0 disables)."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "maintenance_work_mem_kb" {
  description = "maintenance_work_mem in KiB. HNSW/IVFFlat index builds are much faster when the graph fits in memory."
  type        = number
  default     = 524288
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
