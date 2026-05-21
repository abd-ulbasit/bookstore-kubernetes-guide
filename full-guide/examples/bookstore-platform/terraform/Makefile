################################################################################
# Makefile — wrapper around the canonical commands. Read README §5/§8 first.
#
# Common workflow:
#   make init        # one-time provider download
#   make plan        # see what would change
#   make up          # confirms, then terraform apply (~20 min on first apply)
#   make down        # cleanup-pre-destroy.sh + terraform destroy
#   make verify-cleanup
#   make full-cleanup  # = down + verify-cleanup, the safest one-shot
################################################################################

.PHONY: help init fmt validate plan plan-cost up down pre-destroy verify-cleanup full-cleanup clean

# Defaults — `make` reads these via terraform output when state exists.
REGION  ?= $(shell terraform output -raw region       2>/dev/null || echo "us-east-1")
CLUSTER ?= $(shell terraform output -raw cluster_name 2>/dev/null || echo "bookstore-platform")

help:
	@echo "Bookstore Platform — Terraform deploy targets"
	@echo ""
	@echo "  make init           Download providers + initialize state"
	@echo "  make fmt            terraform fmt -recursive (rewrite)"
	@echo "  make validate       terraform validate"
	@echo "  make plan           terraform plan -> tfplan"
	@echo "  make plan-cost      terraform plan + infracost cost breakdown"
	@echo "  make up             Confirm + terraform apply (~20 min first run)"
	@echo "  make pre-destroy    Drain LB Services + PVCs + Karpenter nodes (idempotent)"
	@echo "  make down           pre-destroy + terraform destroy"
	@echo "  make verify-cleanup AWS-CLI orphan scan; exits non-zero on residue"
	@echo "  make full-cleanup   down + verify-cleanup  (safest one-shot)"
	@echo "  make clean          Remove local plan + kubeconfig artifacts"
	@echo ""
	@echo "  REGION  = $(REGION)"
	@echo "  CLUSTER = $(CLUSTER)"

init:
	terraform init

fmt:
	terraform fmt -recursive

validate: init
	terraform validate

plan: init
	terraform plan -out=tfplan

# plan-cost — run a normal terraform plan, then break the cost down with
# infracost. Falls back gracefully if infracost isn't installed.
# Install: `brew install infracost` (or see https://www.infracost.io/docs/).
# First run also needs `infracost auth login` (free, no card required).
plan-cost: init
	@if ! command -v infracost >/dev/null 2>&1; then \
		echo "infracost not found. Install: brew install infracost"; \
		echo "Falling back to plain terraform plan."; \
		terraform plan; \
	else \
		terraform plan -out=tfplan.binary; \
		terraform show -json tfplan.binary > tfplan.json; \
		infracost breakdown --path tfplan.json --show-skipped; \
	fi

up: init
	@echo ""
	@echo "About to create an EKS $(shell grep -E 'default *= *"1\.[0-9]+"' variables.tf | head -1 | sed -E 's/.*"([0-9.]+)".*/\1/') cluster — this costs money."
	@echo "Estimated runtime: 18-22 minutes for the first apply."
	@echo "Estimated idle cost: ~\$$5-8/day (control plane + system nodes + NAT)."
	@echo ""
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
	terraform apply -auto-approve

pre-destroy:
	@echo "Pre-destroy: draining in-cluster LBs + PVCs + Karpenter nodes..."
	./cleanup-pre-destroy.sh

down: pre-destroy
	terraform destroy -auto-approve

verify-cleanup:
	./cleanup-verify.sh --cluster "$(CLUSTER)" --region "$(REGION)"

full-cleanup: down verify-cleanup
	@echo ""
	@echo "Full cleanup complete. Account is clean."

clean:
	rm -f tfplan tfplan.binary tfplan.json kubeconfig.yaml
