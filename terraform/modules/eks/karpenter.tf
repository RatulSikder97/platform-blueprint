# Karpenter v1 prerequisites. The controller itself is installed with Helm
# (see docs/runbook.md); Terraform owns only the AWS-side identity and plumbing.

locals {
  karpenter_queue_name = "${var.cluster_name}-karpenter"
  cluster_tag_key      = "kubernetes.io/cluster/${var.cluster_name}"

  karpenter_events = {
    spot_interruption = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance Rebalance Recommendation"]
    }
    instance_state_change = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance State-change Notification"]
    }
    scheduled_change = {
      source      = ["aws.health"]
      detail_type = ["AWS Health Event"]
    }
  }
}

# ------------------------------------------------------ interruption queue ---

resource "aws_sqs_queue" "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  name                      = local.karpenter_queue_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

data "aws_iam_policy_document" "karpenter_queue" {
  count = var.enable_karpenter ? 1 : 0

  statement {
    sid       = "AllowEventBridge"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter[0].arn]
    principals {
      type        = "Service"
      identifiers = ["events.${local.dns_suffix}", "sqs.${local.dns_suffix}"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.karpenter[0].arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  queue_url = aws_sqs_queue.karpenter[0].url
  policy    = data.aws_iam_policy_document.karpenter_queue[0].json
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = var.enable_karpenter ? local.karpenter_events : {}

  name_prefix = "${var.cluster_name}-karp-"
  description = "Karpenter interruption handling: ${each.key}"
  event_pattern = jsonencode({
    source        = each.value.source
    "detail-type" = each.value.detail_type
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = var.enable_karpenter ? local.karpenter_events : {}

  rule = aws_cloudwatch_event_rule.karpenter[each.key].name
  arn  = aws_sqs_queue.karpenter[0].arn
}

# ------------------------------------------------- controller (Pod Identity) ---

resource "aws_iam_role" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0

  name_prefix        = "${var.cluster_name}-karpenter-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

# Mirrors the upstream Karpenter v1 controller policy: every mutating action is
# scoped to resources tagged for this cluster. Describe*/pricing/SSM reads have
# no resource-level permissions in IAM, hence "*" for those statements only.
data "aws_iam_policy_document" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0

  statement {
    sid     = "AllowScopedEC2InstanceAccessActions"
    actions = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
      "arn:${local.partition}:ec2:${local.region}:*:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:*:subnet/*",
      "arn:${local.partition}:ec2:${local.region}:*:capacity-reservation/*",
    ]
  }

  statement {
    sid       = "AllowScopedEC2LaunchTemplateAccessActions"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:launch-template/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedEC2InstanceActionsWithTags"
    actions = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedResourceCreationTagging"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
    }
  }

  statement {
    sid     = "AllowScopedDeletion"
    actions = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid = "AllowRegionalReadActions"
    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowInterruptionQueueActions"
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
    resources = [aws_sqs_queue.karpenter[0].arn]
  }

  statement {
    sid       = "AllowPassingInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.node.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.${local.dns_suffix}"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileCreationActions"
    actions   = ["iam:CreateInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileTagActions"
    actions   = ["iam:TagInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileActions"
    actions   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.cluster_tag_key}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowInstanceProfileReadActions"
    actions   = ["iam:GetInstanceProfile", "iam:ListInstanceProfiles"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
  }

  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.this.arn]
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0

  name   = "karpenter-controller"
  role   = aws_iam_role.karpenter_controller[0].id
  policy = data.aws_iam_policy_document.karpenter_controller[0].json
}

resource "aws_eks_pod_identity_association" "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.karpenter_namespace
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller[0].arn
  tags            = var.tags
}
