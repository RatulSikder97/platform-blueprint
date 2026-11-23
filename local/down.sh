#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-platform-blueprint}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind delete cluster --name "$CLUSTER"
else
  echo "kind cluster '$CLUSTER' not found; nothing to do"
fi
