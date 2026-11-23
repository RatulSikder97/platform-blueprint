variable "cluster_name" {
  description = "EKS cluster name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}$", var.cluster_name))
    error_message = "cluster_name must be 2-39 chars of lowercase letters, digits and hyphens (leaves room for derived IAM names)."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version (e.g. 1.35)."
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.(3[0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.3x."
  }
}

variable "subnet_ids" {
  description = "Private subnet IDs for the control plane ENIs and managed node groups (one per AZ)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two AZs."
  }
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly. Off by default: reach the API via VPN, SSM port forwarding or CI runners inside the VPC."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint. Must not include 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the Kubernetes API to 0.0.0.0/0."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM role/user ARNs granted cluster-admin through EKS access entries (e.g. an SSO admin role and the CI deploy role)."
  type        = list(string)
  default     = []
}

variable "enabled_cluster_log_types" {
  description = "Control-plane log types shipped to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  validation {
    condition     = alltrue([for t in var.enabled_cluster_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)])
    error_message = "Unknown control-plane log type."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for control-plane logs."
  type        = number
  default     = 90
}

variable "system_node_group" {
  description = <<-EOT
    Managed node group for cluster-critical add-ons (CoreDNS, Karpenter, metrics, ingress).
    Application capacity is expected to come from Karpenter NodePools.
  EOT
  type = object({
    instance_types = optional(list(string), ["m7g.large"])
    ami_type       = optional(string, "AL2023_ARM_64_STANDARD")
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_size_gib  = optional(number, 50)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  })
  default = {}

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.system_node_group.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
  validation {
    condition     = var.system_node_group.min_size <= var.system_node_group.desired_size && var.system_node_group.desired_size <= var.system_node_group.max_size
    error_message = "Require min_size <= desired_size <= max_size."
  }
}

variable "addon_versions" {
  description = "Pin EKS add-on versions (name => version). Unpinned add-ons resolve to the latest version compatible with kubernetes_version."
  type        = map(string)
  default     = {}
}

variable "enable_irsa" {
  description = "Create an IAM OIDC provider for IRSA. Pod Identity is preferred; keep IRSA for tools that do not support it yet."
  type        = bool
  default     = true
}

variable "enable_karpenter" {
  description = "Create Karpenter controller/node IAM, the interruption queue and EventBridge rules."
  type        = bool
  default     = true
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter Helm release is installed into."
  type        = string
  default     = "kube-system"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
