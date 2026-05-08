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
echo "= 1) INIT                     ="
echo "==============================="

INIT_STATUS=$(kubectl -n "${VAULT_NS}" exec vault-0 -- vault status -format=json 2>/dev/null || true)
INITIALIZED=$(echo "${INIT_STATUS:-{}}" | jq -r '.initialized // false')

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
  POD_STATUS=$(kubectl -n "${VAULT_NS}" exec "${pod}" -- vault status -format=json 2>/dev/null || echo '{}')
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
echo "= DONE                        ="
echo "==============================="
cat <<EOF

Verify:
  kubectl -n ${VAULT_NS} exec vault-0 -- env VAULT_TOKEN=${ROOT} vault kv get secret/friendlyhello

Next:
  1) Set vault.enabled=true in apps/friendlyhello/chart/values.yaml
  2) git commit + push
  3) ArgoCD will redeploy friendlyhello with the agent injector annotations
  4) kubectl -n ${APP_NS} logs deploy/friendlyhello -c web | grep API_TOKEN
EOF
