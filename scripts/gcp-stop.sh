#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_tools
require_project

echo
echo "stopping node..."
gcloud container clusters resize "$CLUSTER" --zone "$ZONE" --num-nodes 0 --quiet

echo
echo "node pool at 0 - compute charges stopped"
echo "still billing: load balancer ~\$0.025/hr, disks ~\$0.40/month"
echo "kept intact: postgres data, kafka topics, helm releases, TLS certificate"
