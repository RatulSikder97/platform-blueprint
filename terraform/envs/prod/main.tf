# Production: availability first.
#   - NAT gateway per AZ + interface endpoints for ECR/STS/logs
#   - on-demand system nodes, zone-spread
#   - Multi-AZ RDS with 14-day PITR and deletion protection
#   - primary + replica cache with automatic failover
#   - AMP for long-term metrics

locals {
  environment = "prod"
  name        = "pb-${local.environment}"
}

module "vpc" {
  source = "../../modules/vpc"

  name                     = local.name
  cidr                     = "10.20.0.0/16"
  az_count                 = 3
  nat_gateway_mode         = "per_az"
  cluster_name             = local.name
  interface_endpoints      = ["ecr.api", "ecr.dkr", "sts", "logs"]
  flow_logs_retention_days = 90
}

module "eks" {
  source = "../../modules/eks"

  cluster_name                 = local.name
  kubernetes_version           = "1.35"
  subnet_ids                   = module.vpc.private_subnet_ids
  cluster_admin_principal_arns = var.cluster_admin_principal_arns
  log_retention_days           = 365

  system_node_group = {
    instance_types = ["m7g.large"]
    capacity_type  = "ON_DEMAND"
    min_size       = 3
    desired_size   = 3
    max_size       = 6
    taints = [{
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
}

module "ecr" {
  source = "../../modules/ecr"

  repositories       = ["demo-api"]
  keep_tagged_images = 100
}

module "postgres" {
  source = "../../modules/rds-postgres"

  identifier              = "${local.name}-pg"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.database_subnet_ids
  allowed_security_groups = { eks_cluster = module.eks.cluster_security_group_id }

  instance_class                      = "db.r7g.large"
  allocated_storage_gib               = 100
  max_allocated_storage_gib           = 1000
  multi_az                            = true
  backup_retention_days               = 14
  deletion_protection                 = true
  performance_insights_retention_days = 31
  maintenance_work_mem_kb             = 2097152
}

module "cache" {
  source = "../../modules/elasticache-redis"

  name                    = "${local.name}-cache"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.database_subnet_ids
  allowed_security_groups = { eks_cluster = module.eks.cluster_security_group_id }

  node_type               = "cache.r7g.large"
  num_cache_clusters      = 2
  snapshot_retention_days = 7
}

module "observability" {
  source = "../../modules/observability"

  name                      = local.name
  cluster_name              = module.eks.cluster_name
  enable_managed_prometheus = true
  enable_managed_grafana    = false
  alarm_email               = var.alarm_email
}
