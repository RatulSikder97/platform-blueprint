data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  amp_log_group = "/aws/prometheus/${var.name}"
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.amp_log_group}"]
    }
  }

  # CloudWatch alarms publish to the encrypted SNS topic.
  statement {
    sid       = "CloudWatchAlarmsToSNS"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} observability (AMP, logs, alerts)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

# ------------------------------------------------------------------ alerts ---

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-platform-alerts"
  kms_master_key_id = aws_kms_key.this.arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------- Managed Prometheus (AMP) ---

resource "aws_cloudwatch_log_group" "amp" {
  count = var.enable_managed_prometheus ? 1 : 0

  name              = local.amp_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
  tags              = var.tags
}

resource "aws_prometheus_workspace" "this" {
  count = var.enable_managed_prometheus ? 1 : 0

  alias       = var.name
  kms_key_arn = aws_kms_key.this.arn

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp[0].arn}:*"
  }

  tags = var.tags
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "remote_write" {
  count = var.enable_managed_prometheus ? 1 : 0

  name_prefix        = "${var.name}-amp-write-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "remote_write" {
  count = var.enable_managed_prometheus ? 1 : 0

  statement {
    actions   = ["aps:RemoteWrite"]
    resources = [aws_prometheus_workspace.this[0].arn]
  }
}

resource "aws_iam_role_policy" "remote_write" {
  count = var.enable_managed_prometheus ? 1 : 0

  name   = "amp-remote-write"
  role   = aws_iam_role.remote_write[0].id
  policy = data.aws_iam_policy_document.remote_write[0].json
}

resource "aws_eks_pod_identity_association" "remote_write" {
  count = var.enable_managed_prometheus ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.prometheus_namespace
  service_account = var.prometheus_service_account
  role_arn        = aws_iam_role.remote_write[0].arn
  tags            = var.tags
}

# ------------------------------------------------- Managed Grafana (AMG) ---

data "aws_iam_policy_document" "grafana_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "grafana" {
  count = var.enable_managed_grafana ? 1 : 0

  name_prefix        = "${var.name}-grafana-"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "grafana" {
  for_each = var.enable_managed_grafana ? toset([
    "service-role/AmazonPrometheusQueryAccess",
    "service-role/AmazonGrafanaCloudWatchAccess",
  ]) : toset([])

  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_grafana_workspace" "this" {
  count = var.enable_managed_grafana ? 1 : 0

  name                     = var.name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana[0].arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]
  notification_destinations = [
    "SNS",
  ]
  tags = var.tags
}
