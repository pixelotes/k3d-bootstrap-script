#!/bin/bash
# vault-setup.sh — Initialize, unseal, and configure HashiCorp Vault for the
# friendlyhello demo. Idempotent: safe to re-run after a partial failure.
#
# What it does:
#   1. Init Vault (5 keys / threshold 3) and save unseal data to ~/k3s-lab-vault-init.json
#   2. Unseal all 3 Raft replicas (vault-0/1/2)
#   3. Enable KV v2 at secret/, enable Kubernetes auth, configure host+CA
#   4. Write the 'friendlyhello' policy + role binding the friendlyhello/friendlyhello SA
#   5. Write the demo secret at secret/friendlyhello with key 'api_token'
set -euo pipefail

VAULT_NS="vault"
INIT_FILE="${HOME}/k3s-lab-vault-init.json"
APP_NS="friendlyhello"
APP_SA="friendlyhello"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }
}
require kubectl
require jq

vault_in_pod() {
  # Run a `vault` subcommand inside vault-0 with the root token already exported.
  # Usage: vault_in_pod kv put secret/foo bar=baz
  local token
  token=$(jq -r .root_token "${INIT_FILE}")
  kubectl -n "${VAULT_NS}" exec vault-0 -- env "VAULT_TOKEN=${token}" vault "$@"
}

echo "==============================="
echo "= 0) WAIT FOR VAULT POD       ="
echo "==============================="
# ArgoCD applies the Vault Application asynchronously. vault-0 may not exist yet
# when this script runs (e.g. invoked from start-cluster.sh). Wait up to 5 min.
WAIT_TIMEOUT=300
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
while ! kubectl get ns "${VAULT_NS}" >/dev/null 2>&1; do
  (( $(date +%s) > deadline )) && { echo "Timed out waiting for namespace ${VAULT_NS}" >&2; exit 1; }
  echo "  waiting for namespace ${VAULT_NS}..."
  sleep 3
done

while :; do
  phase=$(kubectl -n "${VAULT_NS}" get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${phase}" == "Running" ]]; then
    echo "  vault-0 is Running"
    break
  fi
  (( $(date +%s) > deadline )) && { echo "Timed out waiting for vault-0 to reach Running (last phase: ${phase:-<missing>})" >&2; exit 1; }
  echo "  waiting for vault-0 (current phase: ${phase:-<not yet created>})..."
  sleep 3
done

echo ""
echo "==============================="
echo "= 1) INIT                     ="
echo "==============================="

INIT_STATUS=$(kubectl -n "${VAULT_NS}" exec vault-0 -- vault status -format=json 2>/dev/null || true)
[[ -z "${INIT_STATUS}" ]] && INIT_STATUS='{}'
INITIALIZED=$(echo "${INIT_STATUS}" | jq -r '.initialized // false')

if [[ "${INITIALIZED}" == "false" ]]; then
  if [[ -f "${INIT_FILE}" ]]; then
    echo "ERROR: Vault reports not initialized but ${INIT_FILE} exists." >&2
    echo "       Either move that file aside, or restore Vault's storage." >&2
    exit 1
  fi
  echo "Initializing Vault (5 keys / threshold 3)..."
  kubectl -n "${VAULT_NS}" exec vault-0 -- vault operator init \
    -key-shares=5 -key-threshold=3 -format=json > "${INIT_FILE}"
  chmod 600 "${INIT_FILE}"
  echo "  Saved init data to ${INIT_FILE}"
  echo "  *** KEEP THIS FILE SAFE — without it you cannot unseal Vault. ***"
else
  echo "Vault already initialized."
  if [[ ! -f "${INIT_FILE}" ]]; then
    echo "ERROR: Vault is initialized but ${INIT_FILE} is missing." >&2
    echo "       Without the unseal keys + root token, you cannot proceed." >&2
    exit 1
  fi
fi

echo ""
echo "==============================="
echo "= 2) UNSEAL                   ="
echo "==============================="

for pod in vault-0 vault-1 vault-2; do
  POD_STATUS=$(kubectl -n "${VAULT_NS}" exec "${pod}" -- vault status -format=json 2>/dev/null || true)
  [[ -z "${POD_STATUS}" ]] && POD_STATUS='{}'
  SEALED=$(echo "${POD_STATUS}" | jq -r '.sealed // true')
  if [[ "${SEALED}" == "false" ]]; then
    echo "  ${pod}: already unsealed"
    continue
  fi
  echo "  ${pod}: unsealing..."
  for i in 0 1 2; do
    KEY=$(jq -r ".unseal_keys_b64[$i]" "${INIT_FILE}")
    kubectl -n "${VAULT_NS}" exec "${pod}" -- vault operator unseal "${KEY}" >/dev/null
  done
done

echo ""
echo "==============================="
echo "= 3) RAFT PEERS               ="
echo "==============================="
vault_in_pod operator raft list-peers

echo ""
echo "==============================="
echo "= 4) CONFIGURE                ="
echo "==============================="

# 4.1 KV v2 at secret/
if vault_in_pod secrets list -format=json | jq -e '.["secret/"]' >/dev/null 2>&1; then
  echo "  KV v2 at secret/ already enabled"
else
  echo "  Enabling KV v2 at secret/..."
  vault_in_pod secrets enable -path=secret kv-v2
fi

# 4.2 Kubernetes auth method
if vault_in_pod auth list -format=json | jq -e '.["kubernetes/"]' >/dev/null 2>&1; then
  echo "  Kubernetes auth already enabled"
else
  echo "  Enabling Kubernetes auth..."
  vault_in_pod auth enable kubernetes
fi

# 4.3 Configure k8s auth (always re-applied — values come from inside the pod)
echo "  Writing kubernetes auth config..."
ROOT=$(jq -r .root_token "${INIT_FILE}")
kubectl -n "${VAULT_NS}" exec vault-0 -- env "VAULT_TOKEN=${ROOT}" sh -c '
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  >/dev/null
'

# 4.4 Policy
echo "  Writing policy 'friendlyhello'..."
kubectl -n "${VAULT_NS}" exec -i vault-0 -- env "VAULT_TOKEN=${ROOT}" vault policy write friendlyhello - <<'POLICY' >/dev/null
path "secret/data/friendlyhello" {
  capabilities = ["read"]
}
POLICY

# 4.5 Role binding the k8s SA → policy
echo "  Creating role 'friendlyhello'..."
vault_in_pod write auth/kubernetes/role/friendlyhello \
  bound_service_account_names="${APP_SA}" \
  bound_service_account_namespaces="${APP_NS}" \
  policies=friendlyhello \
  ttl=1h >/dev/null

# 4.6 Demo secret
echo "  Writing demo secret at secret/friendlyhello..."
vault_in_pod kv put secret/friendlyhello api_token="s3cr3t-from-vault-$(date +%s)" >/dev/null

echo ""
echo "==============================="
echo "= 5) FLIP friendlyhello       ="
echo "==============================="
# Patch the ArgoCD Application in-cluster to force vault.enabled=true via
# spec.source.helm.values. ArgoCD merges this on top of chart/values.yaml.
# NOTE: this is an in-cluster override. Re-applying argocd/friendlyhello.yaml from
# this repo overwrites it; edit chart/values.yaml + commit to make it permanent.
if kubectl -n argocd get application friendlyhello >/dev/null 2>&1; then
  echo "  Patching ArgoCD Application 'friendlyhello' (vault.enabled=true)..."
  kubectl -n argocd patch application friendlyhello --type=merge -p \
    '{"spec":{"source":{"helm":{"values":"vault:\n  enabled: true\n"}}}}' >/dev/null
  kubectl -n argocd annotate application friendlyhello \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  echo "  ArgoCD will re-render the chart and roll new pods with the Vault Agent sidecar."
else
  echo "  friendlyhello Application not deployed yet — skipping patch."
  echo "  Deploy it (./deploy.sh friendlyhello) and re-run this script, or set"
  echo "  vault.enabled=true in apps/friendlyhello/chart/values.yaml and push."
fi

echo ""
echo "==============================="
echo "= DONE                        ="
echo "==============================="
cat <<EOF

Verify the secret is in Vault:
  kubectl -n ${VAULT_NS} exec vault-0 -- env VAULT_TOKEN=${ROOT} vault kv get secret/friendlyhello

Verify the injection landed in the friendlyhello pods (after ArgoCD re-renders):
  kubectl -n ${APP_NS} get pods                                    # 2/2 containers per pod
  kubectl -n ${APP_NS} logs deploy/friendlyhello -c web | grep API_TOKEN

To make the injection persist across argocd/friendlyhello.yaml re-applies:
  set vault.enabled=true in apps/friendlyhello/chart/values.yaml and push to Git.
EOF
