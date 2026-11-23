output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the API server."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (attached to control plane ENIs and nodes)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for IRSA (null when enable_irsa = false)."
  value       = try(aws_iam_openid_connect_provider.this[0].arn, null)
}

output "node_role_arn" {
  description = "IAM role used by system and Karpenter nodes."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name to reference from the Karpenter EC2NodeClass (spec.role)."
  value       = aws_iam_role.node.name
}

output "kms_key_arn" {
  description = "CMK used for Secrets encryption and control-plane logs."
  value       = aws_kms_key.this.arn
}

output "karpenter_queue_name" {
  description = "SQS interruption queue name for the Karpenter Helm value settings.interruptionQueue."
  value       = try(aws_sqs_queue.karpenter[0].name, null)
}

output "karpenter_controller_role_arn" {
  description = "IAM role bound to the karpenter service account via Pod Identity."
  value       = try(aws_iam_role.karpenter_controller[0].arn, null)
}
