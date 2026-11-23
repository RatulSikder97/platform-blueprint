# ADR 0002: NAT gateway strategy per environment

- Status: accepted
- Date: 2026-11-24

## Context

Private subnets need egress for LLM provider APIs, OS/package mirrors and AWS
APIs. NAT gateways are billed per hour (~$33/month each in us-east-1) **and**
per GB processed ($0.045/GB). Cross-AZ traffic to a NAT in another AZ adds
$0.01/GB in each direction. Container image pulls can easily dominate NAT
processing charges.

## Decision

`modules/vpc` exposes `nat_gateway_mode = none | single | per_az`:

| Env | Mode | Rationale |
|---|---|---|
| staging | `single` | Saves ~$66/month. Losing one AZ's NAT for a while is acceptable. |
| prod | `per_az` | Egress survives an AZ failure, with no cross-AZ data charges. |

Both environments always get the **S3 gateway endpoint** (free), which carries
ECR image layers off the NAT path. Prod also adds **interface endpoints** for
`ecr.api`, `ecr.dkr`, `sts` and `logs` (~$7.30/month each per AZ), so image
pulls, Pod Identity credential exchange and log shipping keep working even if
NAT is degraded.

Each AZ always has its own private route table, so changing modes only
rewrites routes and never re-associates subnets. That makes the change
non-disruptive.

## Consequences

- Prod pays ~$99/month for NAT plus ~$88/month for endpoints before data processing. The endpoints pay for themselves once image pulls exceed ~2 TB/month through NAT.
- Third parties that need an IP allow-list (some LLM gateways do) get `nat_public_ips` from Terraform outputs. In `per_az` mode that's three addresses.
- `none` is supported for fully private workloads, for example self-hosted models that only need ECR/S3/STS through endpoints.
