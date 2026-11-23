# Offline unit tests: the AWS provider is mocked, nothing is created.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name         = "test"
  cluster_name = "test-eks"
}

run "per_az_nat_is_default" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "per_az mode should create one NAT gateway per AZ"
  }
  assert {
    condition     = length(aws_subnet.private) == 3 && length(aws_subnet.public) == 3 && length(aws_subnet.database) == 3
    error_message = "expected three subnets per tier"
  }
  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.16.0/20" && aws_subnet.public[0].cidr_block == "10.0.0.0/24" && aws_subnet.database[0].cidr_block == "10.0.10.0/24"
    error_message = "unexpected subnet layout"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "public subnets must not auto-assign public IPs"
  }
  assert {
    condition     = aws_subnet.private[0].tags["karpenter.sh/discovery"] == "test-eks"
    error_message = "private subnets need the Karpenter discovery tag"
  }
  assert {
    condition     = length(aws_flow_log.this) == 1
    error_message = "flow logs should be on by default"
  }
}

run "single_nat" {
  command = plan

  variables {
    nat_gateway_mode = "single"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_nat) == 3
    error_message = "single mode: one NAT gateway, every private route table routes through it"
  }
}

run "no_nat" {
  command = plan

  variables {
    nat_gateway_mode         = "none"
    interface_endpoints      = ["ecr.api", "ecr.dkr", "sts"]
    flow_logs_retention_days = 0
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.private_nat) == 0
    error_message = "none mode must not create NAT gateways or default routes"
  }
  assert {
    condition     = length(aws_vpc_endpoint.interface) == 3
    error_message = "interface endpoints not created"
  }
  assert {
    condition     = length(aws_flow_log.this) == 0
    error_message = "flow logs should be disabled when retention is 0"
  }
}

run "two_az_small_vpc" {
  command = plan

  variables {
    az_count = 2
    cidr     = "10.20.0.0/20"
  }

  assert {
    condition     = length(aws_subnet.private) == 2 && aws_subnet.private[0].cidr_block == "10.20.1.0/24"
    error_message = "a /20 VPC should yield /24 private subnets"
  }
}

run "rejects_invalid_nat_mode" {
  command = plan

  variables {
    nat_gateway_mode = "two"
  }

  expect_failures = [var.nat_gateway_mode]
}

run "rejects_oversized_cidr" {
  command = plan

  variables {
    cidr = "10.0.0.0/8"
  }

  expect_failures = [var.cidr]
}
