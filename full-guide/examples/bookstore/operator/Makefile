# Bookstore operator Makefile (Kubebuilder v4 style, trimmed to what Part 11
# ch.02 uses). Tooling (controller-gen, kustomize, setup-envtest) is fetched
# into ./bin on demand and PINNED — never `latest` — so builds are reproducible
# (same convention as the guide's other pinned tool installs).

IMG ?= bookstore/operator:dev
CONTAINER_TOOL ?= docker

# Pinned tool versions.
CONTROLLER_TOOLS_VERSION ?= v0.16.4
KUSTOMIZE_VERSION ?= v5.4.3
ENVTEST_VERSION ?= release-0.19
ENVTEST_K8S_VERSION ?= 1.31.0

LOCALBIN ?= $(shell pwd)/bin
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
KUSTOMIZE ?= $(LOCALBIN)/kustomize
ENVTEST ?= $(LOCALBIN)/setup-envtest

.PHONY: all
all: build

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

$(LOCALBIN):
	mkdir -p $(LOCALBIN)

.PHONY: controller-gen
controller-gen: $(LOCALBIN) ## Install controller-gen (pinned).
	test -s $(CONTROLLER_GEN) || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: kustomize
kustomize: $(LOCALBIN) ## Install kustomize (pinned).
	test -s $(KUSTOMIZE) || GOBIN=$(LOCALBIN) go install sigs.k8s.io/kustomize/kustomize/v5@$(KUSTOMIZE_VERSION)

.PHONY: envtest
envtest: $(LOCALBIN) ## Install setup-envtest (pinned).
	test -s $(ENVTEST) || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@$(ENVTEST_VERSION)

.PHONY: manifests
manifests: controller-gen ## Generate CRDs, RBAC and webhook YAML into config/.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook \
		paths="./api/..." paths="./internal/..." \
		output:crd:artifacts:config=config/crd \
		output:rbac:artifacts:config=config/rbac \
		output:webhook:artifacts:config=config/webhook

.PHONY: generate
generate: controller-gen ## Regenerate zz_generated.deepcopy.go.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./api/..."

.PHONY: fmt
fmt: ## Run go fmt.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet (the chapter's required check).
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run unit + envtest suites.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" \
		go test ./... -coverprofile cover.out

.PHONY: build
build: manifests generate fmt vet ## Build the manager binary.
	go build -o bin/manager ./cmd

.PHONY: run
run: manifests generate fmt vet ## Run the controller locally (webhooks off).
	ENABLE_WEBHOOKS=false go run ./cmd

.PHONY: docker-build
docker-build: ## Build the manager container image.
	$(CONTAINER_TOOL) build -t $(IMG) .

.PHONY: install
install: manifests kustomize ## Install CRDs into the cluster.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Remove CRDs from the cluster.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy the operator (manager + RBAC + webhooks).
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy the operator.
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found -f -
