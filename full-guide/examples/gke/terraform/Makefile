# GKE lab: spin up, work, tear down. Nodes bill per second while the cluster is up.

TFVARS ?= terraform.tfvars

.PHONY: help init plan up creds status down nuke

help:
	@echo "make up      - plan, show the diff, then create the cluster"
	@echo "make creds   - point kubectl at it"
	@echo "make status  - what exists right now, and for how long"
	@echo "make down    - destroy everything (do this every time you stop)"

init:
	terraform init -input=false

plan: init
	terraform plan -input=false -var-file=$(TFVARS)

up: plan
	@echo ""
	@echo ">>> This creates billable resources. Nodes bill per second."
	@read -p ">>> Type 'yes' to apply: " ok && [ "$$ok" = "yes" ]
	terraform apply -input=false -auto-approve -var-file=$(TFVARS)
	@$(MAKE) creds

creds:
	@eval "$$(terraform output -raw kubectl_config_command)"
	kubectl get nodes -o wide

status:
	@echo "--- terraform ---"
	@terraform state list 2>/dev/null | sed 's/^/  /' || echo "  (no state: nothing created)"
	@echo "--- cluster ---"
	@gcloud container clusters list --format="table(name,location,status,currentNodeCount,createTime)" 2>/dev/null || true
	@echo "--- nodes (these are what cost money) ---"
	@gcloud compute instances list --format="table(name,zone,machineType,scheduling.provisioningModel,status,creationTimestamp)" 2>/dev/null || true

down:
	terraform destroy -input=false -auto-approve -var-file=$(TFVARS)
	@echo ">>> Verify nothing is left:"
	@gcloud compute instances list 2>/dev/null || true
	@gcloud container clusters list 2>/dev/null || true

# Belt and braces: if terraform state is lost, delete by name anyway.
nuke:
	-gcloud container clusters delete $$(grep cluster_name $(TFVARS) | cut -d'"' -f2) --zone $$(grep '^zone' $(TFVARS) | cut -d'"' -f2) --quiet
