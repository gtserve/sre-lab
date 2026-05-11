# ------------------------------------------------------------------------------
# Makefile for the SRE Lab.
# ------------------------------------------------------------------------------
# Single entry point for bootstrapping and tearing down the local lab.
#
# Usage: `make` or `make help` to list available targets.
# ------------------------------------------------------------------------------

SHELL       	:= /usr/bin/env bash
.SHELLFLAGS 	:= -euo pipefail -c
.DEFAULT_GOAL 	:= help

# Cluster identity. Must match `name:` in cluster/kind-config.yaml.
CLUSTER_NAME ?= atlas
KIND_CONFIG  ?= cluster/kind-config.yaml

# Background ArgoCD UI port-forward — PID + log files live in /tmp so
# they don't litter the repo and don't need .gitignore entries.
ARGOCD_UI_PORT ?= 8081
ARGOCD_UI_PID  := /tmp/argocd-ui.pid
ARGOCD_UI_LOG  := /tmp/argocd-ui.log

.PHONY: help cluster-up cluster-down cluster-status

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / \
	  {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

cluster-up: ## Create the local kind cluster
	@echo "==> Creating kind cluster '$(CLUSTER_NAME)'..."
	kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG)

cluster-down: ## Delete the local kind cluster
	@echo "==> Deleting kind cluster '$(CLUSTER_NAME)'..."
	kind delete cluster --name $(CLUSTER_NAME)

cluster-status: ## Show cluster nodes and current kubectl context
	@echo "Current context: $$(kubectl config current-context)"
	@kubectl get nodes -o wide

.PHONY: argocd-install argocd-wait argocd-password argocd-ui

argocd-install: ## Install ArgoCD into the cluster (kustomize over upstream)
	@echo "==> Applying platform/argocd kustomization..."
	kubectl apply -k platform/argocd
	@$(MAKE) --no-print-directory argocd-wait

argocd-wait: ## Wait for all ArgoCD deployments to be Available
	@echo "==> Waiting for ArgoCD deployments to become Available..."
	kubectl -n argocd wait \
	  --for=condition=available deployment --all --timeout=5m
	@echo "==> ArgoCD ready"

argocd-password: ## Print the initial admin password (user: admin)
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d ; echo

argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:8081
	@echo "==> ArgoCD UI: https://localhost:8081 (user: admin)"
	@echo "==> Get password in another terminal: make argocd-password"
	kubectl -n argocd port-forward svc/argocd-server 8081:443

.PHONY: argocd-ui-bg argocd-ui-stop

argocd-ui-bg: ## Port-forward the ArgoCD UI in the background
	@if [ -f $(ARGOCD_UI_PID) ] \
	    && kill -0 $$(cat $(ARGOCD_UI_PID)) 2>/dev/null; then \
	  echo "ArgoCD UI already running (PID $$(cat $(ARGOCD_UI_PID)))"; \
	else \
	  nohup kubectl -n argocd port-forward svc/argocd-server \
	    $(ARGOCD_UI_PORT):443 > $(ARGOCD_UI_LOG) 2>&1 & \
	    echo $$! > $(ARGOCD_UI_PID); \
	  sleep 1; \
	  echo "==> ArgoCD UI: https://localhost:$(ARGOCD_UI_PORT)"; \
	  echo "==> User: admin   Password: make argocd-password"; \
	  echo "==> PID:  $(ARGOCD_UI_PID)"; \
	  echo "==> Log:  $(ARGOCD_UI_LOG)"; \
	  echo "==> Stop: make argocd-ui-stop"; \
	fi

argocd-ui-stop: ## Stop the background ArgoCD UI port-forward
	@if [ ! -f $(ARGOCD_UI_PID) ]; then \
	  echo "No PID file at $(ARGOCD_UI_PID); nothing to stop."; \
	else \
	  PID=$$(cat $(ARGOCD_UI_PID)); \
	  if kill -0 $$PID 2>/dev/null; then \
	    kill $$PID && echo "Stopped ArgoCD UI (PID $$PID)"; \
	  else \
	    echo "PID $$PID not running; removing stale PID file."; \
	  fi; \
	  rm -f $(ARGOCD_UI_PID); \
	fi
