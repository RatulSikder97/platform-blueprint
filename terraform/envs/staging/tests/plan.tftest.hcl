# Offline plan of the whole environment with a mocked AWS provider.
# Proves module wiring, variable validation and environment-specific sizing
# without credentials. Run: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
}

mock_provider "random" {}

run "staging_plan" {
  command = plan

  assert {
    condition     = length(module.vpc.nat_gateway_ids) == 1
    error_message = "staging should use a single NAT gateway"
  }
  assert {
    condition     = module.eks.cluster_name == "pb-staging"
    error_message = "unexpected cluster name"
  }
}
