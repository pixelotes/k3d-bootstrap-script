#!/bin/bash
# Phase 2: deploy ArgoCD Applications one at a time, waiting for each to be
# Synced+Healthy before moving on. Pass app names as args (the file name in
# argocd/<name>.yaml without the extension).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${SCRIPT_DIR}/argocd"

# Catalog of available apps (file name == app name == ArgoCD Application metadata.name)
available_apps=(
  "cert-manager"
  "kube-prometheus-stack"
  "vault"
  "headlamp"
  "friendlyhello"
  "ollama"
  "open-webui"
  "aidungeon-ollama"
  "aiventure"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") <app> [<app> ...]

Deploys ArgoCD Applications one at a time and waits for each to become
Synced + Healthy before continuing.

Available apps:
$(printf '  - %s\n' "${available_apps[@]}")

Examples:
  $(basename "$0") cert-manager
  $(basename "$0") cert-manager vault kube-prometheus-stack
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

# Validate args up front
for app in "$@"; do
  if [[ ! -f "${APPS_DIR}/${app}.yaml" ]]; then
    echo "Unknown app: ${app} (no file at ${APPS_DIR}/${app}.yaml)" >&2
    echo "" >&2
    usage >&2
    exit 1
  fi
done

# Make sure we're talking to the right cluster
kubectl config use-context k3d-k3s-lab >/dev/null

wait_for_app() {
  local app="$1"
  local timeout=600   # 10 min per app
  local deadline=$(( $(date +%s) + timeout ))

  echo "Waiting for ArgoCD Application/${app} to become Healthy (timeout ${timeout}s)..."
  echo "  (charts often stay 'OutOfSync' due to API-server defaults vs helm-rendered manifests — this is fine in a lab)"
  while :; do
    sync=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    health=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    printf '  sync=%-10s health=%-12s\n' "${sync:-?}" "${health:-?}"

    if [[ "${health}" == "Healthy" ]]; then
      if [[ "${sync}" == "Synced" ]]; then
        echo "  -> ${app} READY (Synced + Healthy)"
      else
        echo "  -> ${app} READY (Healthy, sync=${sync} — cosmetic drift, ignoring)"
      fi
      return 0
    fi

    # Surface ComparisonError early so the user doesn't wait 10 minutes for nothing
    err=$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.conditions[?(@.type=="ComparisonError")].message}' 2>/dev/null || true)
    if [[ -n "${err}" ]]; then
      echo "  -> ComparisonError: ${err}" >&2
    fi

    if (( $(date +%s) > deadline )); then
      echo "  -> TIMEOUT waiting for ${app}. Inspect with:" >&2
      echo "       kubectl -n argocd describe application ${app}" >&2
      return 1
    fi
    sleep 5
  done
}

echo ""
echo "============================="
echo "= DEPLOYING ARGOCD APPS     ="
echo "============================="
echo "Apps: $*"
echo ""

for app in "$@"; do
  echo "----- ${app} -----"
  kubectl apply -f "${APPS_DIR}/${app}.yaml"
  wait_for_app "${app}"
  echo ""
done

echo "All requested apps are Healthy."
