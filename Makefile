# Makefile — the standard developer entry points for this repo.
#
# Why a Makefile when most of the work is content + CI? Two reasons:
#   1. New contributors get a single place to discover "what can I run?"
#   2. CI workflows can call the same targets, so what runs locally and what
#      runs in CI are demonstrably the same thing.

.DEFAULT_GOAL := help

# Use bash + strict mode so a recipe that fails mid-way actually fails.
SHELL    := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# Tools — override on the command line if your env differs:
#   make MKDOCS=mkdocs HELM=helm KUBECTL=kubectl ...
MKDOCS   ?= mkdocs
HELM     ?= helm
KUBECTL  ?= kubectl
TERRAFORM ?= terraform
NODE     ?= node
NPM      ?= npm
GO       ?= go
PY       ?= python3

REPO_ROOT := $(shell pwd)

##@ Help

.PHONY: help
help: ## Print this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Site

.PHONY: install
install: ## Install MkDocs Material + plugins (run once per machine).
	$(PY) -m pip install -r requirements.txt

.PHONY: serve
serve: ## Serve the site locally at http://localhost:8000 with live-reload.
	$(MKDOCS) serve -a 0.0.0.0:8000

.PHONY: build
build: ## Build the static site into ./site (mkdocs --strict — fails on any warning).
	$(MKDOCS) build --strict

.PHONY: clean
clean: ## Remove build outputs and node_modules.
	rm -rf site/ node_modules/ /tmp/mkdocs-venv

##@ Validation

.PHONY: validate
validate: validate-mermaid validate-helm validate-kustomize validate-terraform validate-go validate-links ## Run every validator.

.PHONY: validate-mermaid
validate-mermaid: ## Validate every ```mermaid block against the production parser.
	@command -v $(NODE) >/dev/null || (echo "node not found; install Node 20+" && exit 1)
	@test -d node_modules/mermaid || $(NPM) install --silent --no-save mermaid@10.9.1 jsdom
	$(NODE) .github/scripts/validate-mermaid.mjs full-guide

.PHONY: validate-helm
validate-helm: ## helm lint + asserts the canonical Bookstore chart renders 49 manifests.
	$(HELM) lint full-guide/examples/bookstore/helm/bookstore
	@COUNT=$$($(HELM) template bookstore full-guide/examples/bookstore/helm/bookstore | grep -c '^kind:'); \
	echo "rendered kinds = $$COUNT"; \
	[ "$$COUNT" -eq 49 ] || { echo "FAIL — expected 49 got $$COUNT"; exit 1; }

.PHONY: validate-kustomize
validate-kustomize: ## Asserts dev=45 staging=49 prod=48 manifest counts on the overlays.
	@for entry in dev:45 staging:49 prod:48; do \
		OVERLAY="$${entry%:*}"; EXPECTED="$${entry#*:}"; \
		COUNT=$$($(KUBECTL) kustomize "full-guide/examples/bookstore/kustomize/overlays/$$OVERLAY" | grep -c '^kind:'); \
		echo "$$OVERLAY = $$COUNT (expect $$EXPECTED)"; \
		[ "$$COUNT" -eq "$$EXPECTED" ] || { echo "FAIL — $$OVERLAY"; exit 1; }; \
	done

.PHONY: validate-terraform
validate-terraform: ## terraform fmt -check + validate across every tree.
	@for tree in \
		full-guide/examples/bookstore-platform/terraform \
		full-guide/examples/bookstore-platform/terraform-account-baseline \
		full-guide/examples/bookstore-platform/terraform/multi-region; do \
		echo "== $$tree =="; \
		$(TERRAFORM) -chdir=$$tree fmt -recursive -check; \
		$(TERRAFORM) -chdir=$$tree init -backend=false -input=false >/dev/null; \
		$(TERRAFORM) -chdir=$$tree validate; \
	done

.PHONY: validate-go
validate-go: ## go vet + go build on every service that has a go.mod.
	@for svc in catalog orders payments-worker events payments-gateway recommendations search auth; do \
		DIR="full-guide/examples/bookstore-platform/app/$$svc"; \
		[ -f "$$DIR/go.mod" ] || { echo "SKIP — $$svc (no go.mod yet)"; continue; }; \
		echo "== $$svc =="; \
		(cd "$$DIR" && $(GO) vet ./... && $(GO) build ./...); \
	done

.PHONY: validate-links
validate-links: ## mkdocs build --strict (validates every internal link in the guide).
	$(MKDOCS) build --strict

##@ Security

.PHONY: scan
scan: scan-trivy scan-tfsec scan-go ## Run every security scanner; populates SECURITY-SCAN.md material.

.PHONY: scan-trivy
scan-trivy: ## Trivy filesystem scan (vulnerabilities + secrets + misconfigs).
	@command -v trivy >/dev/null || (echo "trivy not found; brew install trivy" && exit 1)
	trivy fs --severity HIGH,CRITICAL --scanners vuln,secret,misconfig .

.PHONY: scan-tfsec
scan-tfsec: ## tfsec across all Terraform trees.
	@command -v tfsec >/dev/null || (echo "tfsec not found; brew install tfsec" && exit 1)
	tfsec full-guide/examples/bookstore-platform/terraform
	tfsec full-guide/examples/bookstore-platform/terraform-account-baseline

.PHONY: scan-go
scan-go: ## govulncheck across every Go service.
	@command -v govulncheck >/dev/null || (echo "govulncheck not found; go install golang.org/x/vuln/cmd/govulncheck@latest" && exit 1)
	@for svc in catalog orders payments-worker events payments-gateway recommendations search auth; do \
		DIR="full-guide/examples/bookstore-platform/app/$$svc"; \
		[ -f "$$DIR/go.mod" ] || continue; \
		echo "== $$svc =="; \
		(cd "$$DIR" && govulncheck ./...); \
	done

##@ Bookstore (local cluster)

.PHONY: kind-up
kind-up: ## Create a local 'bookstore' kind cluster.
	kind create cluster --name bookstore

.PHONY: kind-down
kind-down: ## Delete the local 'bookstore' kind cluster.
	kind delete cluster --name bookstore

.PHONY: deploy
deploy: ## Helm install the canonical Bookstore chart into the current kubectl context.
	$(HELM) upgrade --install bookstore full-guide/examples/bookstore/helm/bookstore --create-namespace --namespace bookstore
