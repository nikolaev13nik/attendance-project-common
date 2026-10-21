#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_tools
require_project
use_cluster_context

echo
echo "starting node..."
gcloud container clusters resize "$CLUSTER" --zone "$ZONE" --num-nodes 1 --quiet

echo
echo "waiting for workloads (up to 10 min)..."
kubectl -n "$APP_NAMESPACE" wait --for=condition=available deploy --all --timeout=10m

echo
kubectl -n "$APP_NAMESPACE" get pods

echo
echo "ready: $APP_URL"
