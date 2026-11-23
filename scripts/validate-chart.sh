#!/usr/bin/env bash
# Lint and schema-validate the service chart against several value sets.
set -euo pipefail

CHART_DIR="${CHART_DIR:-charts/service}"
K8S_VERSION="${K8S_VERSION:-1.35.0}"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

value_sets=("" "$CHART_DIR"/ci/*.yaml local/values-demo-api.yaml deploy/*/values-*.yaml)

for values in "${value_sets[@]}"; do
  args=()
  [[ -n "$values" ]] && args=(-f "$values")
  label="${values:-defaults}"

  echo "==> helm lint ($label)"
  helm lint "$CHART_DIR" --strict ${args[@]+"${args[@]}"}

  echo "==> kubeconform ($label)"
  helm template validate "$CHART_DIR" ${args[@]+"${args[@]}"} \
    | kubeconform -strict -summary \
        -kubernetes-version "$K8S_VERSION" \
        -schema-location default \
        -schema-location "$CRD_SCHEMAS"
done

echo "==> kubeconform (platform manifests)"
kubeconform -strict -summary \
  -kubernetes-version "$K8S_VERSION" \
  -schema-location default \
  -schema-location "$CRD_SCHEMAS" \
  platform/
