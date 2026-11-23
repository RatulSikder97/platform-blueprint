# ADR 0004: Cost posture and the main levers

- Status: accepted
- Date: 2026-11-24

## Context

For LLM-backed services, the dominant variable cost is usually **model spend**,
not infrastructure. The platform should therefore have a predictable floor
cost, scale compute with traffic, and make token usage visible.

## Decisions

1. **Graviton by default.** System nodes (`m7g`), RDS (`db.t4g`/`db.r7g`) and the cache (`cache.t4g`/`cache.r7g`) run on ARM for roughly 15-20% better price/performance. The demo image is built multi-arch-ready (`--platform=$BUILDPLATFORM`, `CGO_ENABLED=0`).
2. **Karpenter with spot plus consolidation.** Application capacity comes from a NodePool that allows spot and on-demand, `WhenEmptyOrUnderutilized` consolidation, and a 10% disruption budget. Staging runs even its system nodes on spot.
3. **Valkey instead of Redis OSS** on ElastiCache. It's protocol-compatible and its node-hour price is roughly 20% lower.
4. **NAT is environment-specific** (see ADR 0002), and the S3 gateway endpoint is always on.
5. **Only metered telemetry gets retention caps.** Flow logs are kept 14 days in staging and 90 in prod. Control-plane logs are kept 30 days in staging and 365 in prod. AMP is prod-only.
6. **Token usage is a first-class metric.** `llm_tokens_total{backend,model,direction}` makes cost-per-route and cost-per-model queryable in PromQL. Example: `sum by (model) (rate(llm_tokens_total{direction="output"}[1h]))` multiplied by the price per token.

## Estimated monthly run-rate (us-east-1, on-demand list prices, **estimate only**)

The estimate excludes data transfer, NAT/endpoint per-GB processing, AMP
ingestion volume and LLM API spend. Spot prices fluctuate, and these numbers
were not taken from a bill.

| Component | staging | prod |
|---|---:|---:|
| EKS control plane | $73 | $73 |
| System nodes | ~$45 (2x m7g.large spot) | ~$179 (3x m7g.large) |
| Karpenter app nodes (example load) | ~$45 (2x m7g.large spot) | ~$357 (3x m7g.xlarge) |
| NAT gateways (hourly) | $33 | $99 |
| Interface endpoints | n/a | ~$88 (4 x 3 AZ) |
| RDS PostgreSQL | ~$50 (t4g.medium, single-AZ, 20 GB) | ~$372 (r7g.large Multi-AZ, 100 GB) |
| ElastiCache Valkey | ~$19 (1x t4g.small) | ~$256 (2x r7g.large) |
| KMS, CloudWatch Logs, SNS, Secrets Manager | ~$25 | ~$80 |
| **Total (approx.)** | **~$290 / month** | **~$1,500 / month** |

## Levers if the bill needs to drop

- Prod RDS: a Reserved Instance or Database Savings Plan for 1 year saves about 30-40%.
- Compute Savings Plan on the steady-state on-demand baseline (system nodes plus the minimum app replicas).
- Drop prod interface endpoints if image pulls are small and NAT HA is enough.
- Scale staging to zero outside working hours: Karpenter NodePool `limits.cpu: 0` plus RDS stop/start.
