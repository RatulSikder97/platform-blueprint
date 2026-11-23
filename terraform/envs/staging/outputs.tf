output "cluster_name" {
  description = "EKS cluster name (aws eks update-kubeconfig --name ...)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "karpenter" {
  description = "Values for the Karpenter Helm release and EC2NodeClass."
  value = {
    interruption_queue = module.eks.karpenter_queue_name
    node_role_name     = module.eks.node_role_name
  }
}

output "ecr_repository_urls" {
  description = "Image repositories."
  value       = module.ecr.repository_urls
}

output "postgres" {
  description = "PostgreSQL connection info; credentials live in Secrets Manager."
  value = {
    endpoint   = module.postgres.endpoint
    port       = module.postgres.port
    database   = module.postgres.database_name
    secret_arn = module.postgres.master_user_secret_arn
  }
}

output "cache" {
  description = "Cache connection info; AUTH token lives in Secrets Manager."
  value = {
    endpoint   = module.cache.primary_endpoint
    port       = module.cache.port
    secret_arn = module.cache.auth_secret_arn
  }
}

output "nat_public_ips" {
  description = "Egress IPs to allow-list with external LLM providers."
  value       = module.vpc.nat_public_ips
}
