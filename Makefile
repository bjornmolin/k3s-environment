SHELL := /bin/bash

OS := $(shell uname -s)

# On Linux, k3s uses its own embedded containerd socket separate from the system containerd.
# Point nerdctl at the k3s socket so built images are available to k3s directly.
# On macOS with Lima, use limactl shell to execute nerdctl inside the VM.
ifeq ($(OS), Linux)
NERDCTL := sudo nerdctl --address /run/k3s/containerd/containerd.sock
else
NERDCTL := limactl shell k3s sudo nerdctl --address /run/k3s/containerd/containerd.sock
endif

.PHONY: setup up sync sync-apps reconcile status stop clean help

## One-time system setup (requires sudo): install tools, configure dnsmasq
setup:
	cd ansible && ansible-playbook -i inventory/localhost.yml setup.yml --ask-become-pass

## Start k3s and deploy via Flux (no sudo required)
up:
	cd ansible && ansible-playbook -i inventory/localhost.yml playbook.yml

## Re-apply infrastructure Flux manifests after editing flux/ files
sync:
	kubectl apply -k flux/infrastructure/sources/
	kubectl apply -k flux/infrastructure/namespaces/
	kubectl apply -k flux/infrastructure/cert-manager/
	kubectl apply -k flux/infrastructure/cilium/
	kubectl apply -k flux/infrastructure/sealed-secrets/
	kubectl apply -k flux/infrastructure/garage/
	kubectl apply -k flux/infrastructure/monitoring/
	kubectl apply -k flux/infrastructure/strimzi/
	kubectl apply -k flux/infrastructure/registry/
	kubectl apply -k flux/infrastructure/forgejo/
	kubectl apply -k flux/infrastructure/kyverno/
	kubectl apply -k flux/infrastructure/builds/

## Force Flux to re-pull from the gitops repo and reconcile apps
sync-apps:
	flux reconcile source git wallet-local-gitops
	flux reconcile kustomization apps-kafka-cluster
	flux reconcile kustomization apps-kafbat
	flux reconcile kustomization apps-valkey
	flux reconcile kustomization apps-headlamp

## Force Flux to reconcile HelmReleases immediately
reconcile:
	flux reconcile helmrelease cert-manager -n cert-manager
	flux reconcile helmrelease cilium -n kube-system
	flux reconcile helmrelease sealed-secrets -n kube-system
	flux reconcile helmrelease garage -n garage
	flux reconcile helmrelease kube-prometheus-stack -n monitoring
	flux reconcile helmrelease loki -n monitoring
	flux reconcile helmrelease vector -n monitoring
	flux reconcile helmrelease strimzi-kafka-operator -n kafka
	flux reconcile helmrelease zot -n registry
	flux reconcile helmrelease forgejo -n forgejo
	flux reconcile helmrelease kyverno -n kyverno
	flux reconcile helmrelease kafbat-ui -n default
	flux reconcile helmrelease valkey -n default

## Show Flux status
status:
	@echo "=== Git Sources ==="
	@flux get sources git
	@echo ""
	@echo "=== Kustomizations ==="
	@flux get kustomizations
	@echo ""
	@echo "=== HelmReleases ==="
	@flux get helmreleases -A

## Stop k3s (preserves data)
stop:
ifeq ($(OS), Darwin)
	@echo "Stopping Lima k3s VM..."
	@if limactl list | grep -q "^k3s"; then \
		limactl stop k3s; \
		echo "Lima k3s VM stopped"; \
	else \
		echo "Lima k3s VM does not exist"; \
	fi
else ifeq ($(OS), Linux)
	@echo "Stopping k3s service..."
	@sudo systemctl stop k3s || sudo service k3s stop
	@echo "k3s service stopped"
else
	@echo "Unsupported OS: $(OS)"
endif

## Destroy k3s completely
clean:
ifeq ($(OS), Darwin)
	@echo "Deleting Lima k3s VM..."
	@if limactl list | grep -q "^k3s"; then \
		limactl delete --force k3s; \
		echo "Lima k3s VM deleted"; \
	else \
		echo "Lima k3s VM does not exist"; \
	fi
	@echo "Cleaning up kubeconfig..."
	@rm -f ~/.kube/config
else ifeq ($(OS), Linux)
	@echo "Uninstalling k3s..."
	@if [ -f /usr/local/bin/k3s-uninstall.sh ]; then \
		sudo /usr/local/bin/k3s-uninstall.sh; \
		echo "k3s uninstalled"; \
	else \
		echo "k3s not installed"; \
	fi
else
	@echo "Unsupported OS: $(OS)"
endif

## Display available targets
help:
	@echo "Available targets:"
	@echo "  setup      - One-time system setup (requires sudo): tools + dnsmasq"
	@echo "  up         - Start k3s and deploy via Flux (no sudo)"
	@echo "  sync       - Re-apply infrastructure Flux manifests"
	@echo "  sync-apps  - Force Flux to re-pull gitops repo and reconcile apps"
	@echo "  reconcile  - Force Flux to reconcile HelmReleases immediately"
	@echo "  status     - Show Flux sources, kustomizations, and HelmReleases"
	@echo "  stop       - Stop k3s (preserves data)"
	@echo "  clean      - Destroy k3s completely"
	@echo ""
	@echo "Container runtime:"
	@echo "  NERDCTL = $(NERDCTL)"
