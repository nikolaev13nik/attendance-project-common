#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_tools
require_project

echo
echo "--- nodes ---"
gcloud compute instances list --filter="name~gke-${CLUSTER}" --format="table(name,status,EXTERNAL_IP)" 2>/dev/null || echo "none running"

echo
echo "--- workloads ---"
if kubectl -n "$APP_NAMESPACE" get pods 2>/dev/null; then
  echo
  echo "--- certificate ---"
  kubectl -n "$APP_NAMESPACE" get certificate 2>/dev/null || true
else
  echo "cluster unreachable - node is probably at 0"
fi

echo
echo "--- endpoint ---"
curl -sS -o /dev/null -m 10 -w "%{http_code}\n" "$APP_URL" 2>/dev/null || echo "unreachable"
