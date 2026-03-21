# K3s Local Development Environment

Declarative local Kubernetes environment using **Ansible** for host bootstrap, **Flux** for GitOps, **Cilium** for networking, and **Forgejo** for self-hosted git.

## Prerequisites

- `make`
- `ansible` (with `community.general` collection)
- macOS: Xcode Command Line Tools (`xcode-select --install`)
- Optional: `k9s` for cluster management

```bash
# macOS
brew install ansible
# Linux
sudo apt install ansible

# Required collection
ansible-galaxy collection install community.general
```

## Quick Start

```bash
# One-time: install tools, configure dnsmasq (requires sudo)
make setup

# Start k3s, deploy everything via Flux (no sudo)
make up
```

## Make Targets

| Target | Description | Sudo |
|--------|-------------|------|
| `make setup` | One-time: install tools (kubectl, helm, flux, mkcert, cosign, kubeseal) + configure dnsmasq | yes |
| `make up` | Start k3s, install Cilium, deploy all infrastructure + apps via Flux | no |
| `make sync` | Re-apply infrastructure Flux manifests after editing `flux/` files | no |
| `make sync-apps` | Force Flux to re-pull gitops repo and reconcile apps | no |
| `make reconcile` | Force all HelmReleases to reconcile immediately | no |
| `make status` | Show Flux sources, kustomizations, and HelmReleases | no |
| `make stop` | Stop k3s (preserves data) | no |
| `make clean` | Destroy k3s VM completely | no |

## Endpoints

All `*.dev.local` resolve via dnsmasq. TLS certificates signed by mkcert local CA.

| Service | URL | Description |
|---------|-----|-------------|
| Grafana | https://grafana.dev.local | Dashboards, metrics, logs |
| Hubble | https://hubble.dev.local | Cilium network flow visibility |
| Forgejo | https://forgejo.dev.local | Git hosting + CI (Actions) |
| KafBat | https://kafbat.dev.local | Kafka cluster UI |
| Headlamp | https://headlamp.dev.local | Kubernetes UI |
| Zot Registry | https://registry.dev.local | OCI container/artifact registry |

## Credentials

All passwords are auto-generated and stored as Sealed Secrets. Retrieve them with:

### Grafana

```bash
# Username
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.username}' | base64 -d; echo

# Password
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d; echo
```

### Forgejo (admin)

```bash
# Username: forgejo_admin
kubectl get secret forgejo-admin -n forgejo -o jsonpath='{.data.password}' | base64 -d; echo
```

### Forgejo (gitops user)

```bash
# Username: gitops
kubectl get secret forgejo-gitops-user -n forgejo -o jsonpath='{.data.password}' | base64 -d; echo
```

### Headlamp

Headlamp uses a ServiceAccount token. Create one with:

```bash
kubectl create token headlamp -n headlamp --duration=24h
```

## Architecture

```
k3s/
  ansible/                 Ansible playbooks & roles
    setup.yml              One-time system setup (sudo)
    playbook.yml           Day-to-day startup (no sudo)
    roles/
      prerequisites/       Install tools (kubectl, helm, flux, mkcert, cosign, kubeseal)
      k3s/                 Start k3s (Lima on macOS, systemd on Linux)
      dnsmasq/             Configure *.dev.local wildcard DNS
      flux/                Install Flux + Cilium, deploy infrastructure, configure Forgejo + GitOps

  flux/infrastructure/     Flux manifests (applied directly by Ansible)
    sources/               HelmRepository CRs
    namespaces/            Namespace resources
    cilium/                Cilium CNI + Gateway API + Hubble + TLS certificate
    cert-manager/          cert-manager + mkcert ClusterIssuer
    sealed-secrets/        Sealed Secrets controller
    monitoring/            Prometheus + Grafana + Loki + Vector
    garage/                Garage S3 object storage (backs Loki)
    strimzi/               Strimzi Kafka operator
    registry/              Zot OCI registry
    forgejo/               Forgejo git server + Actions runner
    kyverno/               Kyverno admission controller (image signature verification)
    builds/                Flux Image Update Automation

  gitops-config.yaml       Configures the gitops repo URL + build definitions
  lima-k3s.yaml            Lima VM config (macOS)
```

### GitOps Repo (wallet-local-gitops)

Hosted in Forgejo at `gitops/wallet-local-gitops`. Flux watches this repo and auto-deploys.

```
apps/
  kafka-cluster/           Strimzi Kafka (3 controllers + 3 brokers, KRaft)
  kafbat/                  KafBat Kafka UI
  valkey/                  Valkey (Redis alternative, Sentinel HA)
  headlamp/                Headlamp Kubernetes UI
```

## Modifying Infrastructure

Edit files under `flux/infrastructure/`, then:

```bash
make sync       # Apply changes
make reconcile  # Force immediate reconciliation
make status     # Verify
```

## Modifying App Deployments

Push changes to the gitops repo in Forgejo:

```bash
cd wallet-local-gitops
# edit files...
git add -A && git commit -m "update deployment"
GIT_SSL_NO_VERIFY=1 git push forgejo main
# Or wait ~1 minute for Flux to auto-pull
make sync-apps  # Force immediate pull
```

## Forgejo Actions Runner

The runner is deployed with `replicas: 0` by default. To activate:

1. Log in to https://forgejo.dev.local as `forgejo_admin`
2. Go to **Site Administration > Actions > Runners > Create new Runner**
3. Copy the registration token
4. Create the secret and scale up:

```bash
kubectl create secret generic forgejo-runner-token -n forgejo --from-literal=token=YOUR_TOKEN
kubectl scale deployment forgejo-runner -n forgejo --replicas=1
```

## Observability Stack

| Component | Role |
|-----------|------|
| Prometheus | Metrics collection (kube-prometheus-stack) |
| Grafana | Dashboards + visualization |
| Loki | Log aggregation (S3 backend via Garage) |
| Vector | Log collection (DaemonSet, ships to Loki) |
| Hubble | Cilium network flow observability |

Pre-loaded Grafana dashboards: Kafka, Valkey, HSM Worker, BFF REST API.

## Networking

| Component | Role |
|-----------|------|
| Cilium | CNI (eBPF), replaces Flannel + kube-proxy |
| Cilium Gateway API | Ingress (replaces Traefik), HTTPS termination |
| Hubble | Network flow monitoring |
| cert-manager + mkcert | Wildcard TLS for `*.dev.local` |
| dnsmasq | Local DNS resolution |

## Supply Chain (planned)

| Component | Role |
|-----------|------|
| Forgejo Actions | CI/CD (GitHub Actions compatible) |
| Buildah | Container image builds (daemonless, rootless) |
| Cosign | Image signing |
| Zot | OCI registry (stores images + signatures) |
| Kyverno | Admission-time signature verification |
| Flux Image Automation | Auto-update gitops repo with new image tags |

## Troubleshooting

```bash
# Check all HelmReleases
flux get helmreleases -A

# Check Flux sources
flux get sources git

# Check Flux kustomizations
flux get kustomizations

# Check Cilium health
kubectl exec -n kube-system ds/cilium -- cilium-dbg status --brief

# Check Gateway routes
kubectl get gateways,httproutes -A

# Check certificates
kubectl get certificates -A

# Check sealed secrets
kubectl get sealedsecrets -A

# View logs for a component
kubectl logs -n <namespace> deploy/<name> --tail=50

# Force reconcile a single HelmRelease
flux reconcile helmrelease <name> -n <namespace>
```
