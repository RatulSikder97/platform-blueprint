# ADR 0001: EKS over ECS Fargate for the service platform

- Status: accepted
- Date: 2026-11-24

## Context

We run many small HTTP services that call LLM providers, plus supporting
in-cluster software: Prometheus, External Secrets, an ingress controller, and
eventually GPU or self-hosted inference workloads. The team already works with
Kubernetes manifests and Helm.

## Options

1. **ECS on Fargate.** No nodes to manage, deep AWS integration, a cheap control plane (free). Weaker ecosystem for operators/CRDs, per-task pricing, no GPUs on Fargate, and service-mesh/autoscaling options are AWS-specific.
2. **EKS + Karpenter.** $73/month per control plane plus node operations. You get the full Kubernetes ecosystem (operators, HPA/KEDA, NetworkPolicy, ServiceMonitor), bin-packing on spot and Graviton, GPU node pools, and portable manifests.

## Decision

Use **EKS** with a small managed node group for cluster-critical add-ons and
**Karpenter** for all application capacity.

## Consequences

- One reusable Helm chart (`charts/service`) defines the contract for every service: probes, security context, HPA, PDB, NetworkPolicy, metrics, secrets.
- We own node lifecycle. Karpenter `expireAfter: 720h`, drift detection and the `AL2023 @latest` alias keep nodes patched, and EKS managed add-ons cover CNI/CoreDNS/kube-proxy upgrades.
- Each cluster costs a fixed ~$73/month, so we don't run one cluster per team. Namespaces, NetworkPolicy and access entries provide isolation.
- If a future workload is a single stateless container with no in-cluster dependencies, ECS Fargate is still a valid choice and doesn't conflict with this ADR.
