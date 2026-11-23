data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  port           = 6379
  family         = "${var.engine}${split(".", var.engine_version)[0]}"
  log_group_name = "/aws/elasticache/${var.name}/slow-log"
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} ElastiCache at-rest, auth token secret and logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/elasticache/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_elasticache_subnet_group" "this" {
  name        = var.name
  description = "${var.name} isolated subnets"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-cache-"
  description = "Cache access for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cache" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  description                  = "Cache from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
}

resource "aws_elasticache_parameter_group" "this" {
  name        = "${var.name}-${local.family}"
  family      = local.family
  description = "${var.name} parameters"

  parameter {
    name  = "maxmemory-policy"
    value = var.maxmemory_policy
  }

  tags = var.tags
}

# AUTH token: generated here, stored in Secrets Manager for External Secrets.
# Note it also lands in Terraform state, which is why state is KMS-encrypted.
resource "random_password" "auth" {
  length           = 48
  special          = true
  override_special = "!&#$^<>-"
}

resource "aws_secretsmanager_secret" "auth" {
  name_prefix             = "${var.name}/auth-"
  description             = "AUTH token for ElastiCache ${var.name}"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "auth" {
  secret_id = aws_secretsmanager_secret.auth.id
  secret_string = jsonencode({
    host     = aws_elasticache_replication_group.this.primary_endpoint_address
    port     = local.port
    password = random_password.auth.result
    tls      = true
  })
}

resource "aws_cloudwatch_log_group" "slow_log" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
  tags              = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "${var.name} (${var.engine})"

  engine               = var.engine
  engine_version       = var.engine_version
  node_type            = var.node_type
  port                 = local.port
  parameter_group_name = aws_elasticache_parameter_group.this.name

  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.this.arn
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = random_password.auth.result
  auth_token_update_strategy = "ROTATE"

  snapshot_retention_limit   = var.snapshot_retention_days
  snapshot_window            = "02:00-03:00"
  maintenance_window         = "sun:05:00-sun:06:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.slow_log.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  tags = var.tags
}
