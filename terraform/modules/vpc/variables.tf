variable "name" {
  description = "Name prefix for all VPC resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be 2-31 chars of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "cidr" {
  description = "VPC IPv4 CIDR. /16 to /20; private subnets get 1/16 of it each (sized for VPC-CNI pod IPs)."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) >= 16 && tonumber(split("/", var.cidr)[1]) <= 20
    error_message = "cidr must be a valid IPv4 CIDR with a prefix length between /16 and /20."
  }
}

variable "az_count" {
  description = "Number of availability zones to span."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (RDS/ElastiCache subnet groups need at least 2 AZs)."
  }
}

variable "nat_gateway_mode" {
  description = <<-EOT
    Egress strategy for private subnets:
      none   - no NAT; private subnets only reach AWS via VPC endpoints.
      single - one NAT gateway in the first AZ (cheap, AZ failure kills egress).
      per_az - one NAT gateway per AZ (HA, no cross-AZ data charges).
  EOT
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be one of: none, single, per_az."
  }
}

variable "cluster_name" {
  description = "EKS cluster name used for subnet discovery tags (kubernetes.io/cluster/*, karpenter.sh/discovery). Empty disables the tags."
  type        = string
  default     = ""
}

variable "interface_endpoints" {
  description = "AWS services to expose via interface VPC endpoints (e.g. [\"ecr.api\", \"ecr.dkr\", \"sts\", \"logs\"]). The S3 gateway endpoint is always created."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.interface_endpoints : can(regex("^[a-z0-9.-]+$", s))])
    error_message = "interface_endpoints entries must be bare service names such as ecr.api or sts."
  }
}

variable "flow_logs_retention_days" {
  description = "Retention for VPC flow logs in CloudWatch. 0 disables flow logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be 0 or a CloudWatch-supported retention value."
  }
}

variable "tags" {
  description = "Tags applied to every resource (merged with provider default_tags)."
  type        = map(string)
  default     = {}
}
