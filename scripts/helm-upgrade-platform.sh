#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

require_tools
require_project
use_cluster_context

echo
helm upgrade platform ../helm/platform \
  -f ../helm/platform/values-gcp.yaml \
  -n "$PLATFORM_RELEASE_NAMESPACE"
