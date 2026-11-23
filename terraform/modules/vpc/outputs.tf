output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC IPv4 CIDR."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability zones in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (one per AZ)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for EKS nodes and pods (one per AZ)."
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "Isolated database subnet IDs (one per AZ)."
  value       = aws_subnet.database[*].id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs (empty when nat_gateway_mode = none)."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "NAT gateway egress IPs, useful for third-party allow-lists (e.g. LLM providers)."
  value       = aws_eip.nat[*].public_ip
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ)."
  value       = aws_route_table.private[*].id
}
