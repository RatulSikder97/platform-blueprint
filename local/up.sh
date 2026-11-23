#!/usr/bin/env bash
# Create a kind cluster, install the observability stack and deploy demo-api
# through the reusable service chart. Idempotent: safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${CLUSTER:-platform-blueprint}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-demo-api}"
IMAGE="demo-api:local"
KPS_VERSION="${KPS_VERSION:-93.9.0}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-3.14.0}"

log() { printf '\n==> %s\n' "$*"; }

for bin in kind kubectl helm docker; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "kind cluster '$CLUSTER' already exists"
else
  log "creating kind cluster '$CLUSTER'"
  kind create cluster --name "$CLUSTER" --config "$ROOT/local/kind-config.yaml" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

log "building $IMAGE"
docker build -t "$IMAGE" --build-arg VERSION=local "$ROOT/apps/demo-api"
kind load docker-image "$IMAGE" --name "$CLUSTER"

log "installing helm repositories"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo update prometheus-community metrics-server >/dev/null

log "installing metrics-server $METRICS_SERVER_VERSION (HPA resource metrics)"
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "$METRICS_SERVER_VERSION" --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' --wait --timeout 5m

log "installing kube-prometheus-stack $KPS_VERSION"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" --namespace monitoring --create-namespace \
  -f "$ROOT/local/values-kube-prometheus-stack.yaml" --wait --timeout 10m

# helm --wait only covers resources in the release. The Prometheus StatefulSet
# is created afterwards by the operator, so wait for it explicitly.
log "waiting for Prometheus (operator-managed StatefulSet)"
PROM_STS="prometheus-kube-prometheus-stack-prometheus"
for _ in $(seq 1 60); do
  kubectl -n monitoring get statefulset "$PROM_STS" >/dev/null 2>&1 && break
  sleep 2
done
kubectl -n monitoring rollout status "statefulset/$PROM_STS" --timeout 5m

log "deploying $RELEASE via charts/service"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Force a new rollout when the locally built image changes under the same tag.
IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}' | cut -c8-19)"
helm upgrade --install "$RELEASE" "$ROOT/charts/service" \
  --namespace "$NAMESPACE" \
  -f "$ROOT/local/values-demo-api.yaml" \
  --set-string "podAnnotations.local/image-id=$IMAGE_ID" \
  --wait --timeout 5m

kubectl -n "$NAMESPACE" get deploy,pods,svc,hpa,pdb,networkpolicy,servicemonitor -o wide
log "done. Run 'make local-test' to exercise the service."
