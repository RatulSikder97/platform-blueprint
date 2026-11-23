# ---------------------------------------------------------- node IAM role ---
# Shared by the managed system node group and Karpenter-launched nodes.

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "node" {
  # Deterministic name: the Karpenter EC2NodeClass references it by name.
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# Karpenter nodes join through an EC2_LINUX access entry (no aws-auth ConfigMap).
resource "aws_eks_access_entry" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
  tags          = var.tags
}

# ------------------------------------------------------- system node group ---

resource "aws_launch_template" "system" {
  name_prefix            = "${var.cluster_name}-system-"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # pods cannot reach IMDS; they use Pod Identity
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.system_node_group.disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-system" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-system" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  ami_type       = var.system_node_group.ami_type
  capacity_type  = var.system_node_group.capacity_type
  instance_types = var.system_node_group.instance_types

  scaling_config {
    min_size     = var.system_node_group.min_size
    max_size     = var.system_node_group.max_size
    desired_size = var.system_node_group.desired_size
  }

  update_config {
    max_unavailable_percentage = 33
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = merge({ "node.platform/pool" = "system" }, var.system_node_group.labels)

  dynamic "taint" {
    for_each = var.system_node_group.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = var.tags

  lifecycle {
    # Cluster Autoscaler / manual scaling may change desired size; don't fight it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
