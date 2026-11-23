data "aws_partition" "current" {}

resource "aws_kms_key" "this" {
  description             = "${var.identifier} RDS storage, Performance Insights and master secret"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/rds/${var.identifier}"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.identifier}-"
  description = "${var.identifier} isolated subnets"
  subnet_ids  = var.subnet_ids
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "this" {
  name_prefix = "${var.identifier}-rds-"
  description = "PostgreSQL access for ${var.identifier}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.identifier}-rds" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from ${each.key}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.identifier}-pg${var.engine_major_version}-"
  family      = "postgres${var.engine_major_version}"
  description = "${var.identifier}: TLS-only, query stats, pgvector-friendly memory"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # pgvector index builds (HNSW) are memory bound.
  parameter {
    name  = "maintenance_work_mem"
    value = tostring(var.maintenance_work_mem_kb)
  }

  parameter {
    name  = "max_parallel_maintenance_workers"
    value = "2"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name_prefix        = "${var.identifier}-rds-mon-"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier = var.identifier

  engine                     = "postgres"
  engine_version             = var.engine_major_version
  auto_minor_version_upgrade = true
  instance_class             = var.instance_class
  parameter_group_name       = aws_db_parameter_group.this.name
  ca_cert_identifier         = "rds-ca-rsa2048-g1"

  db_name                       = var.database_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  iam_database_authentication_enabled = true

  allocated_storage     = var.allocated_storage_gib
  max_allocated_storage = max(var.max_allocated_storage_gib, var.allocated_storage_gib)
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  network_type           = "IPV4"

  backup_retention_period   = var.backup_retention_days
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.identifier}-final"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.this.arn
  performance_insights_retention_period = var.performance_insights_retention_days

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = var.tags

  lifecycle {
    # RDS applies minor upgrades itself (auto_minor_version_upgrade).
    ignore_changes = [engine_version]
  }

  depends_on = [aws_iam_role_policy_attachment.monitoring]
}
