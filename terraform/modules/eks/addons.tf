locals {
  # Add-ons that must exist before nodes join vs. ones that need nodes to schedule.
  addons_pre_nodes  = ["vpc-cni", "kube-proxy", "eks-pod-identity-agent"]
  addons_post_nodes = ["coredns", "aws-ebs-csi-driver"]
  addons            = concat(local.addons_pre_nodes, local.addons_post_nodes)
}

data "aws_eks_addon_version" "this" {
  for_each = toset([for a in local.addons : a if !contains(keys(var.addon_versions), a)])

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "pre_nodes" {
  for_each = toset(local.addons_pre_nodes)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = lookup(var.addon_versions, each.value, try(data.aws_eks_addon_version.this[each.value].version, null))
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  configuration_values = each.value == "vpc-cni" ? jsonencode({
    env = {
      # Prefix delegation raises pod density per ENI (important on small nodes).
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
    # Enforce Kubernetes NetworkPolicy natively via the VPC CNI eBPF agent.
    enableNetworkPolicy = "true"
  }) : null

  tags = var.tags
}

resource "aws_eks_addon" "post_nodes" {
  for_each = toset(local.addons_post_nodes)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = lookup(var.addon_versions, each.value, try(data.aws_eks_addon_version.this[each.value].version, null))
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  dynamic "pod_identity_association" {
    for_each = each.value == "aws-ebs-csi-driver" ? [1] : []
    content {
      role_arn        = aws_iam_role.ebs_csi.arn
      service_account = "ebs-csi-controller-sa"
    }
  }

  tags = var.tags

  depends_on = [aws_eks_node_group.system, aws_eks_addon.pre_nodes]
}

# --------------------------------------------------- EBS CSI (Pod Identity) ---

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.${local.dns_suffix}"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.cluster_name}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
