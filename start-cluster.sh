#!/bin/bash
# Bootstrap: create the k3d cluster, install ArgoCD, then deploy the apps listed
# in `apps` below — one at a time, waiting for each to become Synced + Healthy.
# Empty/comment the array if you only want the cluster + ArgoCD and will run
# ./deploy.sh <app> manually.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="k3s-lab"

# === Apps to deploy after ArgoCD is up (file name in argocd/<name>.yaml) ===
# Order matters: each app must be Synced+Healthy before the next one starts.
apps=(
  "headlamp"
  # "cert-manager"
  # "kube-prometheus-stack"
  # "vault"
)

# 0) Pre-flight checks
for bin in docker kubectl k3d; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Missing required binary: $bin" >&2
    exit 1
  fi
done

# 1) Create cluster (idempotent)
if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
  echo "Cluster ${CLUSTER_NAME} already exists, reusing it."
else
  k3d cluster create --config "${SCRIPT_DIR}/config/k3d-config.yaml"
fi

kubectl config use-context "k3d-${CLUSTER_NAME}"

# Inotify bumps for the platform stack (matches the kind-bootstrap-script pattern)
for node in $(k3d node list --no-headers | awk -v c="${CLUSTER_NAME}" '$0 ~ c {print $1}'); do
  docker exec "${node}" sh -c "sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true"
  docker exec "${node}" sh -c "sysctl -w fs.inotify.max_user_instances=512 >/dev/null 2>&1 || true"
done

# 2) Install ArgoCD
echo ""
echo "=========="
echo "= ARGOCD ="
echo "=========="

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "${SCRIPT_DIR}/apps/argocd/argocd.yaml"

components=(
  "argocd-server"
  "argocd-application-controller"
  "argocd-repo-server"
  "argocd-applicationset-controller"
  "argocd-notifications-controller"
)

for component in "${components[@]}"; do
  echo "Waiting for $component..."
  kubectl wait --namespace argocd \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name="${component}" \
    --timeout=180s
done

# Expose ArgoCD UI on NodePort 30080 (mapped to host 30080 by k3d-config.yaml)
kubectl patch svc argocd-server -n argocd -p \
  '{"spec": {"type": "NodePort", "ports": [{"name": "http", "nodePort": 30080, "port": 80, "protocol": "TCP", "targetPort": 8080}, {"name": "https", "nodePort": 30443, "port": 443, "protocol": "TCP", "targetPort": 8080}]}}'

while ! kubectl get secret argocd-initial-admin-secret --namespace argocd >/dev/null 2>&1; do
  echo "Waiting for argocd-initial-admin-secret..."
  sleep 2
done

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "======================"
echo "= ARGOCD CREDENTIALS ="
echo "======================"
echo "URL:      http://localhost:30080"
echo "User:     admin"
echo "Password: ${ARGOCD_PASS}"

# 3) Deploy ArgoCD apps (one at a time, waiting for each — see deploy.sh)
if [[ ${#apps[@]} -gt 0 ]]; then
  "${SCRIPT_DIR}/deploy.sh" "${apps[@]}"
fi

cat <<EOF

=================================
= CLUSTER READY                 =
=================================
Context:    k3d-${CLUSTER_NAME}
ArgoCD UI:  http://localhost:30080  (admin / ${ARGOCD_PASS})

To deploy more apps later, e.g.:
  ./deploy.sh cert-manager
  ./deploy.sh kube-prometheus-stack
  ./deploy.sh vault
EOF
