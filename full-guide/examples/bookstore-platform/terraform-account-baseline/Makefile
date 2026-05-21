################################################################################
# Makefile — wrapper around terraform for the account-baseline tree.
#
# This is a SEPARATE state from ../terraform/. Run from this directory.
#
# Recommended workflow:
#   make init       # one-time provider download
#   make plan       # see what would change
#   make up         # confirms, then terraform apply
#   make down       # confirms, then terraform destroy
################################################################################

.PHONY: help init fmt validate plan up down clean

help:
	@echo "Account Baseline — Terraform targets"
	@echo ""
	@echo "  make init       Download providers + initialize state"
	@echo "  make fmt        terraform fmt -recursive (rewrite)"
	@echo "  make validate   terraform validate"
	@echo "  make plan       terraform plan -> tfplan"
	@echo "  make up         Confirm + terraform apply"
	@echo "  make down       Confirm + terraform destroy"
	@echo "  make clean      Remove local plan artifacts"
	@echo ""
	@echo "This stack is SEPARATE from ../terraform/. Different state file."

init:
	terraform init

fmt:
	terraform fmt -recursive

validate: init
	terraform validate

plan: init
	terraform plan -out=tfplan

up: init
	@echo ""
	@echo "About to enable account-baseline security services (GuardDuty,"
	@echo "Security Hub, Config, CloudTrail, IAM Access Analyzer — whichever"
	@echo "you've toggled on via variables)."
	@echo "These can ADD cost (~$$30-100/month with all enabled, less for some)."
	@echo ""
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
	terraform apply -auto-approve

down:
	@echo ""
	@echo "About to disable the account-baseline services. This will tear down"
	@echo "CloudTrail trails, Security Hub aggregator, Config recorder, etc."
	@echo "Audit log history in S3 buckets is preserved (force_destroy=false)."
	@echo ""
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
	terraform destroy -auto-approve

clean:
	rm -f tfplan
