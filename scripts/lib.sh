#!/usr/bin/env bash
set -euo pipefail

PROJECT="attendance-512211"
CLUSTER="attendance"
ZONE="me-west1-a"
CONTEXT="gke_${PROJECT}_${ZONE}_${CLUSTER}"
APP_NAMESPACE="attendance"
PLATFORM_RELEASE_NAMESPACE="default"
APP_URL="https://nik-attendance-app.duckdns.org"

require_tools() {
  local missing=0
  for tool in gcloud kubectl helm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "ERROR: '$tool' not found on PATH" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

require_project() {
  local active
  active=$(gcloud config get-value project 2>/dev/null || echo "")
  if [ "$active" != "$PROJECT" ]; then
    echo "ERROR: gcloud project is '${active:-unset}', expected '$PROJECT'" >&2
    echo "       run: gcloud config set project $PROJECT" >&2
    exit 1
  fi
  echo "project ok: $PROJECT"
}

use_cluster_context() {
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CONTEXT"; then
    echo "context missing, fetching credentials for '$CLUSTER'"
    gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" >/dev/null 2>&1
  fi

  local current
  current=$(kubectl config current-context 2>/dev/null || echo "none")

  if [ "$current" != "$CONTEXT" ]; then
    echo "context switch: $current -> $CONTEXT"
    kubectl config use-context "$CONTEXT" >/dev/null
  else
    echo "context ok: $CONTEXT"
  fi
}
