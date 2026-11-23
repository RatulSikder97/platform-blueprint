# Staging: same topology as prod, sized and configured for cost.
#   - single NAT gateway          (accepts AZ-level egress risk)
#   - spot system nodes           (Karpenter adds app capacity on demand)
#   - single-AZ RDS / one cache node, short backups, no deletion protection

locals {
  environment = "staging"
  name        = "pb-${local.environment}"
}

module "vpc" {
  source = "../../modules/vpc"

  name                     = local.name
  cidr                     = "10.10.0.0/16"
  az_count                 = 3
  nat_gateway_mode         = "single"
  cluster_name             = local.name
  flow_logs_retention_days = 14
}

module "eks" {
  source = "../../modules/eks"

  cluster_name                 = local.name
  kubernetes_version           = "1.35"
  subnet_ids                   = module.vpc.private_subnet_ids
  cluster_admin_principal_arns = var.cluster_admin_principal_arns
  log_retention_days           = 30

  system_node_group = {
    instance_types = ["m7g.large", "m6g.large", "c7g.xlarge"]
    capacity_type  = "SPOT"
    min_size       = 2
    desired_size   = 2
    max_size       = 3
  }
}

module "ecr" {
  source = "../../modules/ecr"

  repositories       = ["demo-api"]
  keep_tagged_images = 20
}

# Staging DB is disposable (restored from prod snapshots on demand), so
# deletion protection is intentionally off here and only here.
#trivy:ignore:AWS-0177
module "postgres" {
  source = "../../modules/rds-postgres"

  identifier              = "${local.name}-pg"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.database_subnet_ids
  allowed_security_groups = { eks_cluster = module.eks.cluster_security_group_id }

  instance_class        = "db.t4g.medium"
  allocated_storage_gib = 20
  multi_az              = false
  backup_retention_days = 3
  deletion_protection   = false
  monitoring_interval   = 0
}

module "cache" {
  source = "../../modules/elasticache-redis"

  name                    = "${local.name}-cache"
  vpc_id                  = module.vpc.vpc_id
  subnet_ids              = module.vpc.database_subnet_ids
  allowed_security_groups = { eks_cluster = module.eks.cluster_security_group_id }

  node_type               = "cache.t4g.small"
  num_cache_clusters      = 1
  snapshot_retention_days = 0
}

module "observability" {
  source = "../../modules/observability"

  name                      = local.name
  cluster_name              = module.eks.cluster_name
  enable_managed_prometheus = false
  enable_managed_grafana    = false
  alarm_email               = var.alarm_email
}
