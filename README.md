# k3d-bootstrap-script (RA5_2)

Adapts the original [`kind-bootstrap-script`](../kind-bootstrap-script) GitOps pattern to **k3d**, so we can do the *Práctica RA5_2* fully in Docker on macOS — no VMs, no baremetal.

## What this gives you

- A **K3s cluster in Docker** with 2 servers + 2 agents (matches the RA5_2 architecture)
- **Traefik** as the ingress controller (built into K3s)
- **ArgoCD** managing the platform stack:
  - `cert-manager`
  - `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager)
  - `vault` (HashiCorp Vault, **HA with Raft, 3 replicas**)
  - `headlamp` (web UI for the cluster, single pod — sucessor to the now-archived kubernetes-dashboard)
  - `friendlyhello` — the demo app (Flask + Redis) deployed straight from this Git repo

The script is split into **phases on purpose**: trying to deploy everything at once on a laptop usually ends in pods stuck Pending while images pull. You install the cluster, then bring apps up one at a time.

## Prerequisites (macOS)

You already have: Docker (OrbStack), `kubectl`, `helm`.

You still need:

```bash
# Homebrew (if you don't have it yet)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# k3d + lab tooling
brew install k3d k9s

# Optional but mentioned in the practical
brew install vault etcd stern
```

## Layout

```
.
├── start-cluster.sh        Phase 1: create k3d cluster + install ArgoCD
├── deploy.sh               Phase 2: deploy ArgoCD apps one at a time (with wait)
├── stop-cluster.sh         Tear down
├── scripts/
│   └── vault-setup.sh      Init + unseal + configure Vault for the friendlyhello demo
├── config/
│   └── k3d-config.yaml     2 servers + 2 agents, host port mappings
├── argocd/                 One ArgoCD Application per file (file name == app name)
│   ├── cert-manager.yaml
│   ├── kube-prometheus-stack.yaml
│   ├── vault.yaml
│   └── headlamp.yaml       Application + Namespace + admin SA/Secret in one file
└── apps/
    ├── argocd/             ArgoCD itself (chicken-and-egg — installed before Applications can exist)
    │   └── argocd.yaml     Vendored upstream install manifest
    └── friendlyhello/
        ├── app/            Flask app + Dockerfile + requirements.txt
        └── chart/          Minimal Helm chart (ConfigMap + Redis + Deployment + Service + Ingress)
```

## How to run, step by step

### Phase 1 — cluster + ArgoCD + (optionally) initial apps

```bash
./start-cluster.sh
```

When this finishes you have:

- Cluster `k3s-lab` (context `k3d-k3s-lab`), 2 servers + 2 agents
- ArgoCD reachable at <http://localhost:30080> (user `admin`, password printed by the script)
- Whatever you put in the `apps=(...)` array at the top of `start-cluster.sh`, deployed one at a time and waited for `Healthy` before the next one. Default: just `headlamp`.

Sanity check:

```bash
kubectl get nodes
kubectl -n argocd get pods
kubectl -n argocd get applications
```

### Phase 2 — more platform apps, one at a time

Same logic, on demand. Each call applies the ArgoCD Application and **waits until it's `Synced + Healthy`** before returning. If something stalls, you'll see it instead of having a half-deployed cluster.

```bash
./deploy.sh cert-manager
./deploy.sh kube-prometheus-stack
./deploy.sh vault
```

You can pass several at once if you trust they'll come up clean:

```bash
./deploy.sh cert-manager kube-prometheus-stack
```

### Phase 3 — Vault setup (one-time)

Vault HA with Raft starts **sealed**. The `scripts/vault-setup.sh` script is idempotent and does everything: init → unseal → enable KV v2 → enable Kubernetes auth → policy + role for friendlyhello → write the demo secret.

```bash
./scripts/vault-setup.sh
```

It saves the unseal keys + root token to `~/k3s-lab-vault-init.json` (gitignored — **keep it safe**, without it Vault is bricked).

After the script finishes, friendlyhello's Vault demo is one toggle away:

```bash
# Enable Vault Agent injection in the chart
sed -i '' 's/^  enabled: false$/  enabled: true/' apps/friendlyhello/chart/values.yaml
git add apps/friendlyhello/chart/values.yaml
git commit -m "Enable Vault injection for friendlyhello"
git push
```

ArgoCD detects the change and re-renders friendlyhello with the Vault Agent annotations. New pods come up with a `vault-agent-init` initContainer + `vault-agent` sidecar. Verify:

```bash
kubectl -n friendlyhello get pods                                       # 2/2 containers per pod
kubectl -n friendlyhello logs deploy/friendlyhello -c web | grep API_TOKEN
# -> API_TOKEN from Vault: s3cr3t-f...
```

### Phase 4 — Headlamp access

The admin SA, ClusterRoleBinding, and token Secret are bundled into `argocd/headlamp.yaml`, so they're created when you ran `./deploy.sh headlamp`. Just grab the token:

```bash
kubectl -n headlamp get secret headlamp-admin-token \
  -o jsonpath='{.data.token}' | base64 -d; echo

# Open Headlamp
open http://localhost:30090
```

Paste the token in the login form.

### Phase 5 — friendlyhello demo (Docker → K8s)

The image lives on Docker Hub (`pixelotes/friendlyhello:latest`) and the manifests in this very repo, so deployment is now pure GitOps via ArgoCD.

**One-time setup (only when the app code changes):**

```bash
docker login                                                      # first time only
docker build -t pixelotes/friendlyhello:latest apps/friendlyhello/app
docker push pixelotes/friendlyhello:latest
```

**Deploy:**

```bash
./deploy.sh friendlyhello
```

ArgoCD renders `apps/friendlyhello/chart` from this repo as Helm, kubelet pulls the image from Docker Hub, and the rollout starts. Then:

```bash
# Hits Traefik on host port 8080, routed by the Ingress 'friendlyhello.localhost'
curl -H 'Host: friendlyhello.localhost' http://localhost:8080/
curl -H 'Host: friendlyhello.localhost' http://localhost:8080/   # different hostname → round-robin across 5 pods

# Or in the browser
open http://friendlyhello.localhost:8080
```

Mapping back to the docker-compose version of the practical:

| docker-compose            | Kubernetes                                  |
|---------------------------|---------------------------------------------|
| `services: web`           | `Deployment` (`replicas: 5`)                |
| `image: redis`            | Redis `Deployment` + `Service`              |
| `traefik.http.routers...` | `Ingress` with host rule (`Host: localhost`) |
| `environment: NAME=World` | `ConfigMap` + `envFrom`                     |
| `--scale web=5`           | `spec.replicas: 5`                          |

## Day-to-day URLs

| Service               | URL                                  |
|-----------------------|--------------------------------------|
| ArgoCD                | <http://localhost:30080>             |
| Headlamp              | <http://localhost:30090>             |
| Grafana               | <http://grafana.localhost:8080>      |
| friendlyhello         | <http://friendlyhello.localhost:8080> |

## etcd snapshots (RA5_2 § 03)

K3s embeds etcd. Snapshot from any server node:

```bash
docker exec k3d-k3s-lab-server-0 \
  k3s etcd-snapshot save --name lab-snap --dir /var/lib/rancher/k3s/server/db/snapshots
docker exec k3d-k3s-lab-server-0 ls /var/lib/rancher/k3s/server/db/snapshots
```

## Tear down

```bash
./stop-cluster.sh   # k3d cluster delete k3s-lab
```

## What the original `kind-bootstrap-script` provided (and what changed)

| Reused                            | Changed                                                           |
|-----------------------------------|-------------------------------------------------------------------|
| Bootstrap pattern (cluster → ArgoCD → apps) | Cluster engine: `kind` → `k3d`                          |
| Per-app `argocd/<name>.yaml` model | Apps array → explicit args to `deploy.sh` (deploy one at a time) |
| `apps/argocd/argocd.yaml` install | New apps: `vault` (HA Raft), `kube-prometheus-stack`, `headlamp`  |
| `kubernetes-dashboard` Application | Replaced with `headlamp` (project archived in 2025)               |
| `cert-manager` Application        | Bumped to v1.15.3                                                 |
| `stop-cluster.sh`                 | `kind delete` → `k3d cluster delete`                              |

Removed (not in RA5_2): `nginx-ingress` (K3s already ships Traefik), `falco`, `kyverno`, `victoria*`, `external-secrets-operator`.
