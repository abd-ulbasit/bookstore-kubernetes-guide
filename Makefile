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
	rm -rf site/ node_modules/ .github/scripts/node_modules/ /tmp/mkdocs-venv

##@ Validation

.PHONY: validate
validate: validate-mermaid validate-helm validate-kustomize validate-terraform validate-go validate-links ## Run every validator.

.PHONY: validate-mermaid
validate-mermaid: ## Validate every ```mermaid block against the production parser.
	@command -v $(NODE) >/dev/null || (echo "node not found; install Node 24+" && exit 1)
	@test -d .github/scripts/node_modules/mermaid || $(NPM) ci --ignore-scripts --no-audit --no-fund --prefix .github/scripts
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
validate-terraform: ## terraform fmt -check + validate across every Terraform root (TF_ROOTS).
	@for tree in $(TF_ROOTS); do \
		echo "== $$tree =="; \
		$(TERRAFORM) -chdir=$$tree fmt -recursive -check; \
		$(TERRAFORM) -chdir=$$tree init -backend=false -input=false -lockfile=readonly >/dev/null; \
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
scan: scan-trivy scan-terraform scan-go scan-secrets ## Run every security scanner; populates SECURITY-SCAN.md material.

.PHONY: scan-secrets
scan-secrets: ## gitleaks over the full git history, with the repo's allowlist (same as CI).
	@command -v gitleaks >/dev/null || (echo "gitleaks not found; brew install gitleaks (CI pins v8.30.1)" && exit 1)
	gitleaks git --config .gitleaks.toml --redact --exit-code 1 .

.PHONY: scan-trivy
scan-trivy: ## Trivy filesystem scan (vulnerabilities + secrets + misconfigs).
	@command -v trivy >/dev/null || (echo "trivy not found; brew install trivy" && exit 1)
	trivy fs --severity HIGH,CRITICAL --scanners vuln,secret,misconfig --skip-dirs '**/.terraform' .

# The four Terraform roots, one report each. CI does not run this separately:
# `scan-trivy` (and the CI trivy job) already evaluates every root as part of
# the whole-repo misconfig scan. This target exists so a per-tree report is
# one command away when you are working on one tree. It replaced a tfsec
# target that only covered two of the four roots.
TF_ROOTS := \
	full-guide/examples/bookstore-platform/terraform \
	full-guide/examples/bookstore-platform/terraform-account-baseline \
	full-guide/examples/bookstore-platform/terraform/multi-region \
	full-guide/examples/gke/terraform

.PHONY: scan-terraform
scan-terraform: ## Trivy misconfig scan of each Terraform root separately.
	@command -v trivy >/dev/null || (echo "trivy not found; brew install trivy" && exit 1)
	@for tree in $(TF_ROOTS); do \
		echo "== $$tree =="; \
		trivy config --severity HIGH,CRITICAL --skip-dirs '**/.terraform' "$$tree"; \
	done

.PHONY: scan-go
scan-go: ## govulncheck across every Go module under full-guide/examples/.
# Modules are discovered, not listed. The previous version walked a hardcoded
# service list under bookstore-platform/app/ only, so the canonical
# examples/bookstore/ tree was never scanned locally either — the same blind
# spot the CI job had. Discovery keeps `make scan-go` honest as services move
# or get added, and keeps it equivalent to the CI job it stands in for.
	@command -v govulncheck >/dev/null || (echo "govulncheck not found; go install golang.org/x/vuln/cmd/govulncheck@v1.9.0 (the version CI pins)" && exit 1)
	@rc=0; \
	for dir in $$(find full-guide/examples -name go.mod \
	              -not -path '*/vendor/*' -not -path '*/.terraform/*' \
	              -exec dirname {} \; | sort); do \
		echo "== $$dir =="; \
		(cd "$$dir" && govulncheck ./...) || rc=1; \
	done; \
	exit $$rc

##@ Gates

# The security-first gates (docs/security-first-authoring.md, section 8). Each
# target extracts the chapter YAML into a throwaway directory first. SCOPE is a
# space-separated list of chapters or chapter directories relative to
# full-guide/, for example SCOPE=01-core-workloads/01-pods.md. With no SCOPE
# every chapter is in scope. Pick the interpreter with PY=, for example a
# Python 3.12 virtualenv that has PyYAML.
#
# ALSO lists the example trees G2 scans as well. A whole-guide run (no SCOPE)
# scans full-guide/examples; a scoped run scans none unless ALSO= names them.
# ALLOW_CONTEXT= names a kubectl context other than kind-* that G3 may write to.
# REPORT= makes G2 and G3 write their per-block verdicts there as JSON, which
# .github/scripts/gates/chapter_summary.py reads.
# The allowlist file records the not-evaluated blocks someone checked by hand.
GATES_DIR := .github/scripts/gates
GATES_SCOPE := $(foreach s,$(SCOPE),--scope $(s))
ALSO ?= $(if $(SCOPE),,full-guide/examples)
GATES_ALSO := $(foreach p,$(ALSO),--also $(p))
GATES_ALLOW := --allow $(GATES_DIR)/not-evaluated.allow
GATES_CONTEXT := $(foreach c,$(ALLOW_CONTEXT),--allow-context $(c))
GATES_REPORT := $(if $(REPORT),--report $(REPORT))

.PHONY: gates-test
gates-test: ## Run the unit tests of the gate scripts. Needs Trivy, Helm and kubectl: their tests may not be skipped.
	@command -v trivy >/dev/null || (echo "trivy not found; the real-Trivy tests would be skipped. brew install trivy" && exit 1)
	@command -v $(HELM) >/dev/null || (echo "helm not found; the chart-rendering tests would be skipped" && exit 1)
	@command -v $(KUBECTL) >/dev/null || (echo "kubectl not found; the overlay-rendering tests would be skipped" && exit 1)
	REQUIRE_TRIVY=1 $(PY) -m unittest discover -s $(GATES_DIR)

.PHONY: gates-static
gates-static: ## G1+G2: Trivy core checks on chapter YAML (SCOPE=chapter.md ... ALSO=examples dir ...).
	@command -v trivy >/dev/null || (echo "trivy not found; brew install trivy" && exit 1)
	@out=$$(mktemp -d); trap 'rm -rf "$$out"' EXIT; \
	$(PY) $(GATES_DIR)/extract_blocks.py --root full-guide --out "$$out" && \
	$(PY) $(GATES_DIR)/static_gate.py --manifest "$$out/manifest.json" --helm $(HELM) --kubectl $(KUBECTL) $(GATES_SCOPE) $(GATES_ALSO) $(GATES_ALLOW) $(GATES_REPORT)

# G5, the registry half. It always reads the whole guide (SCOPE does not apply)
# and the example trees in ALSO, or full-guide/examples. The two registries are
# .trivyignore.yaml (scanner findings) and security/namespace-exceptions.yaml
# (namespaces above restricted). Trivy is run only if a scanner entry exists.
GATES_REGISTRY_ALSO := $(foreach p,$(or $(ALSO),full-guide/examples),--also $(p))

.PHONY: gates-registry
gates-registry: ## G5: exceptions registered, unexpired (<= 12 months) and still matching (ALSO=examples dir ...).
	$(PY) $(GATES_DIR)/registry_gate.py --root full-guide $(GATES_REGISTRY_ALSO) --helm $(HELM) --kubectl $(KUBECTL)

.PHONY: gates-admission
gates-admission: ## G1+G3: restricted-namespace dry-run of chapter YAML (SCOPE=chapter.md ...). Needs a kind cluster.
	@out=$$(mktemp -d); trap 'rm -rf "$$out"' EXIT; \
	$(PY) $(GATES_DIR)/extract_blocks.py --root full-guide --out "$$out" && \
	$(PY) $(GATES_DIR)/admission_gate.py --manifest "$$out/manifest.json" --kubectl $(KUBECTL) $(GATES_SCOPE) $(GATES_ALLOW) $(GATES_CONTEXT) $(GATES_REPORT)

##@ Bookstore (local cluster)

.PHONY: kind-up
kind-up: ## Create a local 'bookstore' kind cluster.
	kind create cluster --name bookstore

.PHONY: kind-down
kind-down: ## Delete the local 'bookstore' kind cluster.
	kind delete cluster --name bookstore

.PHONY: deploy
deploy: ## Helm install the Bookstore chart into the current kubectl context (creates and labels the namespace first).
	$(KUBECTL) create namespace bookstore --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) label namespace bookstore --overwrite pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
	$(HELM) upgrade --install bookstore full-guide/examples/bookstore/helm/bookstore --namespace bookstore --set namespace.create=false
