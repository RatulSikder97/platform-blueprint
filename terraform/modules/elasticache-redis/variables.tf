variable "name" {
  description = "Replication group ID and name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.name))
    error_message = "name must be 2-40 lowercase alphanumerics/hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated database subnet IDs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide subnets in at least two AZs."
  }
}

variable "allowed_security_groups" {
  description = "Security groups allowed to connect, keyed by a static label (e.g. { eks_nodes = sg-... }). Static keys keep for_each plannable when IDs are unknown until apply."
  type        = map(string)
  default     = {}
}

variable "engine" {
  description = "valkey (Redis OSS-compatible, ~20% cheaper on ElastiCache) or redis."
  type        = string
  default     = "valkey"

  validation {
    condition     = contains(["valkey", "redis"], var.engine)
    error_message = "engine must be valkey or redis."
  }
}

variable "engine_version" {
  description = "Engine version, e.g. 8.1 for valkey or 7.1 for redis."
  type        = string
  default     = "8.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "engine_version must be MAJOR.MINOR."
  }
}

variable "node_type" {
  description = "Cache node type."
  type        = string
  default     = "cache.t4g.small"

  validation {
    condition     = can(regex("^cache\\.", var.node_type))
    error_message = "node_type must start with cache."
  }
}

variable "num_cache_clusters" {
  description = "Primary + replicas. >= 2 enables automatic failover and Multi-AZ."
  type        = number
  default     = 2

  validation {
    condition     = var.num_cache_clusters >= 1 && var.num_cache_clusters <= 6
    error_message = "num_cache_clusters must be between 1 and 6."
  }
}

variable "snapshot_retention_days" {
  description = "Daily snapshot retention (0 disables snapshots; fine for pure caches)."
  type        = number
  default     = 3

  validation {
    condition     = var.snapshot_retention_days >= 0 && var.snapshot_retention_days <= 35
    error_message = "snapshot_retention_days must be between 0 and 35."
  }
}

variable "maxmemory_policy" {
  description = "Eviction policy. allkeys-lru suits LLM response / embedding caches."
  type        = string
  default     = "allkeys-lru"
}

variable "log_retention_days" {
  description = "CloudWatch retention for slow logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
