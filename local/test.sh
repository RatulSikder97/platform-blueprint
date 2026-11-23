#!/usr/bin/env bash
# End-to-end checks against the local deployment:
#   1. helm test hook (in-cluster curl through the Service + NetworkPolicy)
#   2. health, summarize and metrics endpoints via port-forward
#   3. Prometheus has discovered the ServiceMonitor and is scraping the pods
set -euo pipefail

CLUSTER="${CLUSTER:-platform-blueprint}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-demo-api}"
SVC="${SVC:-$RELEASE}"
APP_PORT="${APP_PORT:-18080}"
PROM_PORT="${PROM_PORT:-19090}"

kubectl config use-context "kind-$CLUSTER" >/dev/null

pids=()
cleanup() { for p in "${pids[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

wait_for_port() {
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$1/" && return 0
    sleep 1
  done
  fail "port-forward on :$1 never became ready"
}

echo "==> helm test"
helm test "$RELEASE" -n "$NAMESPACE" --timeout 2m >/dev/null && pass "helm test (in-cluster request via Service)"

kubectl -n "$NAMESPACE" port-forward "svc/$SVC" "$APP_PORT:80" >/dev/null 2>&1 & pids+=($!)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "$PROM_PORT:9090" >/dev/null 2>&1 & pids+=($!)
wait_for_port "$APP_PORT"
wait_for_port "$PROM_PORT"

base="http://127.0.0.1:$APP_PORT"

echo "==> GET /healthz"
curl -fsS "$base/healthz" | tee /dev/stderr | grep -q '"status":"ok"' && pass "healthz"

echo "==> POST /v1/summarize"
resp="$(curl -fsS -X POST "$base/v1/summarize" -H 'Content-Type: application/json' \
  -d '{"text":"Karpenter provisions nodes for pending pods. The cafeteria serves soup on Fridays. Pods scheduled by Karpenter land on right-sized nodes. Nodes are consolidated when pods leave.","max_sentences":2}')"
echo "$resp"
grep -q '"backend":"fake"' <<<"$resp" || fail "unexpected summarize response"
grep -q 'soup' <<<"$resp" && fail "summary kept the off-topic sentence"
pass "summarize"

echo "==> POST /v1/summarize (validation)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/v1/summarize" -H 'Content-Type: application/json' -d '{"text":""}')"
[[ "$code" == "422" ]] || fail "expected 422 for empty text, got $code"
pass "input validation (422)"

echo "==> GET /metrics"
curl -fsS "$base/metrics" | grep -q '^llm_tokens_total{backend="fake"' || fail "llm_tokens_total missing"
pass "metrics exposed"

echo "==> Prometheus scrape of ServiceMonitor target"
query='sum(up{namespace="'"$NAMESPACE"'",service="'"$SVC"'"})'
for i in $(seq 1 24); do
  up="$(curl -fsS --get "http://127.0.0.1:$PROM_PORT/api/v1/query" --data-urlencode "query=$query" \
        | sed -n 's/.*"value":\[[^,]*,"\([0-9.]*\)"\].*/\1/p')"
  if [[ -n "$up" && "${up%.*}" -ge 1 ]]; then
    pass "Prometheus scraping $up demo-api target(s)"
    break
  fi
  [[ $i -eq 24 ]] && fail "Prometheus is not scraping demo-api (query: $query)"
  sleep 5
done

echo "==> NetworkPolicy denies traffic from other namespaces"
if kubectl -n default run "np-probe-$$" --rm -i --restart=Never --quiet \
     --image=curlimages/curl:8.17.0 --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}}}' \
     -- curl -s -o /dev/null --max-time 5 "http://$SVC.$NAMESPACE.svc.cluster.local/healthz" >/dev/null 2>&1; then
  fail "request from namespace 'default' reached $SVC; NetworkPolicy not enforced"
fi
pass "cross-namespace request blocked"

echo
echo "All local e2e checks passed."
