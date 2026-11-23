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

run "prod_plan" {
  command = plan

  assert {
    condition     = length(module.vpc.nat_gateway_ids) == 3
    error_message = "prod needs one NAT gateway per AZ"
  }
  assert {
    condition     = length(module.vpc.private_subnet_ids) == 3 && length(module.vpc.database_subnet_ids) == 3
    error_message = "prod must span three AZs"
  }
  assert {
    condition     = module.eks.cluster_name == "pb-prod"
    error_message = "unexpected cluster name"
  }
}

run "prod_rejects_public_api_to_world" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name           = "pb-prod"
    subnet_ids             = ["subnet-a", "subnet-b"]
    endpoint_public_access = true
    public_access_cidrs    = ["0.0.0.0/0"]
  }

  expect_failures = [var.public_access_cidrs]
}
