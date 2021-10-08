REGISTRY ?= mcr.microsoft.com/oss/azure/workload-identity
PROXY_IMAGE_NAME := proxy
INIT_IMAGE_NAME := proxy-init
WEBHOOK_IMAGE_NAME := webhook
IMAGE_VERSION ?= v0.5.0

ORG_PATH := github.com/Azure
PROJECT_NAME := azure-workload-identity
BUILD_COMMIT := $(shell git rev-parse --short HEAD)
REPO_PATH := "$(ORG_PATH)/$(PROJECT_NAME)"

# build variables
BUILD_TIMESTAMP := $$(date +%Y-%m-%d-%H:%M)
BUILD_TIME_VAR := $(REPO_PATH)/pkg/version.BuildTime
BUILD_VERSION_VAR := $(REPO_PATH)/pkg/version.BuildVersion
VCS_VAR := $(REPO_PATH)/pkg/version.Vcs
LDFLAGS ?= "-X $(BUILD_TIME_VAR)=$(BUILD_TIMESTAMP) -X $(BUILD_VERSION_VAR)=$(IMAGE_VERSION) -X $(VCS_VAR)=$(BUILD_COMMIT)"

PROXY_IMAGE := $(REGISTRY)/$(PROXY_IMAGE_NAME):$(IMAGE_VERSION)
INIT_IMAGE := $(REGISTRY)/$(INIT_IMAGE_NAME):$(IMAGE_VERSION)
WEBHOOK_IMAGE := $(REGISTRY)/$(WEBHOOK_IMAGE_NAME):$(IMAGE_VERSION)

GOOS := $(shell go env GOOS)
GOARCH :=$(shell go env GOARCH)

# Directories
ROOT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BIN_DIR := $(abspath $(ROOT_DIR)/bin)
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(abspath $(TOOLS_DIR)/bin)

# Binaries
CONTROLLER_GEN_VER := v0.5.0
CONTROLLER_GEN_BIN := controller-gen
CONTROLLER_GEN := $(TOOLS_BIN_DIR)/$(CONTROLLER_GEN_BIN)-$(CONTROLLER_GEN_VER)

E2E_TEST_BIN := e2e.test
E2E_TEST := $(BIN_DIR)/$(E2E_TEST_BIN)

GINKGO_VER := v1.16.2
GINKGO_BIN := ginkgo
GINKGO := $(TOOLS_BIN_DIR)/$(GINKGO_BIN)-$(GINKGO_VER)

KIND_VER := v0.11.0
KIND_BIN := kind
KIND := $(TOOLS_BIN_DIR)/$(KIND_BIN)-$(KIND_VER)

KUBECTL_VER := v1.21.2
KUBECTL_BIN := kubectl
KUBECTL := $(TOOLS_BIN_DIR)/$(KUBECTL_BIN)-$(KUBECTL_VER)

KUSTOMIZE_VER := v4.1.2
KUSTOMIZE_BIN := kustomize
KUSTOMIZE := $(TOOLS_BIN_DIR)/$(KUSTOMIZE_BIN)-$(KUSTOMIZE_VER)

GOLANGCI_LINT_VER := v1.41.1
GOLANGCI_LINT_BIN := golangci-lint
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/$(GOLANGCI_LINT_BIN)-$(GOLANGCI_LINT_VER)

SHELLCHECK_VER := v0.7.2
SHELLCHECK_BIN := shellcheck
SHELLCHECK := $(TOOLS_BIN_DIR)/$(SHELLCHECK_BIN)-$(SHELLCHECK_VER)

ENVSUBST_VER := v1.2.0
ENVSUBST_BIN := envsubst
ENVSUBST := $(TOOLS_BIN_DIR)/$(ENVSUBST_BIN)-$(ENVSUBST_VER)

HELM_VER := v3.6.2
HELM_BIN := helm
HELM := $(TOOLS_BIN_DIR)/$(HELM_BIN)-$(HELM_VER)

# Scripts
GO_INSTALL := ./hack/go-install.sh

## --------------------------------------
## Images
## --------------------------------------

OUTPUT_TYPE ?= type=registry
ALL_IMAGES ?= $(PROXY_IMAGE_NAME) $(INIT_IMAGE_NAME) $(WEBHOOK_IMAGE_NAME)
ALL_LINUX_ARCH ?= amd64 arm64

# split words on hyphen, access by 1-index
split-by-hyphen = $(word $2,$(subst -, ,$1))

BUILDX_BUILDER_NAME ?= img-builder
QEMU_VERSION ?= 5.2.0-2

.PHONY: docker-build
docker-build:
	@if ! docker buildx ls | grep $(BUILDX_BUILDER_NAME); then \
		docker run --rm --privileged multiarch/qemu-user-static:$(QEMU_VERSION) --reset -p yes; \
		docker buildx create --name $(BUILDX_BUILDER_NAME) --use; \
		docker buildx inspect $(BUILDX_BUILDER_NAME) --bootstrap; \
	fi
	for img in $(ALL_IMAGES); do \
		for arch in $(ALL_LINUX_ARCH); do \
			IMAGE_NAME=$${img} ARCH=$${arch} $(MAKE) .image-$${img}-$${arch}; \
		done; \
	done

.image-%:
	docker buildx build \
		--build-arg GOARCH=$(ARCH) \
		--build-arg LDFLAGS=$(LDFLAGS) \
		--file docker/$(IMAGE_NAME).Dockerfile \
		--output=$(OUTPUT_TYPE) \
		--platform="linux/$(ARCH)" \
		--pull \
		--tag $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_VERSION)-linux-$(ARCH) .
	@if [ "$(ARCH)" = "amd64" ] && [ "$(OUTPUT_TYPE)" = "type=docker" ]; then \
		docker tag $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_VERSION)-linux-$(ARCH) $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_VERSION); \
	fi
	touch $@

.PHONY: docker-push-manifest
docker-push-manifest:
	for img in $(ALL_IMAGES); do \
		docker manifest create --amend $(REGISTRY)/$${img}:$(IMAGE_VERSION) $(foreach arch,$(ALL_LINUX_ARCH),$(REGISTRY)/$${img}:$(IMAGE_VERSION)-linux-$(arch)); \
		for arch in $(ALL_LINUX_ARCH); do docker manifest annotate --os linux --arch $${arch} $(REGISTRY)/$${img}:$(IMAGE_VERSION) $(REGISTRY)/$${img}:$(IMAGE_VERSION)-linux-$${arch}; done; \
		docker manifest push --purge $(REGISTRY)/$${img}:$(IMAGE_VERSION); \
	done

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"

.PHONY: all
all: manager

# Build manager binary
.PHONY: manager
manager: generate fmt vet
	go build -a -ldflags $(LDFLAGS) -o bin/manager cmd/webhook/main.go

# Build proxy binary
.PHONY: proxy
proxy: fmt vet
	go build -a -ldflags $(LDFLAGS) -o bin/proxy cmd/proxy/main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
.PHONY: run
run: generate fmt vet manifests
	go run .cmd/webhook/main.go

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
ARC_CLUSTER ?= false
AZURE_ENVIRONMENT ?=
AZURE_TENANT_ID ?=

.PHONY: deploy
deploy: $(KUBECTL) $(KUSTOMIZE) $(ENVSUBST)
	$(MAKE) manifests
	cd config/manager && $(KUSTOMIZE) edit set image manager=$(WEBHOOK_IMAGE)
	$(KUSTOMIZE) build config/default | $(ENVSUBST) | $(KUBECTL) apply -f -
	$(KUBECTL) wait --for=condition=Available --timeout=5m -n azure-workload-identity-system deployment/azure-wi-webhook-controller-manager

.PHONY: uninstall-deploy
uninstall-deploy: $(KUBECTL) $(KUSTOMIZE) $(ENVSUBST)
	$(KUSTOMIZE) build config/default | $(ENVSUBST) | $(KUBECTL) delete -f -

## --------------------------------------
## Code Generation
## --------------------------------------

# Generate manifests e.g. CRD, RBAC etc.
.PHONY: manifests
manifests: $(CONTROLLER_GEN) $(KUSTOMIZE)
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..."

	rm -rf manifest_staging
	mkdir -p manifest_staging/deploy
	mkdir -p manifest_staging/charts/workload-identity-webhook

	$(KUSTOMIZE) build config/default -o manifest_staging/deploy/azure-wi-webhook.yaml
	$(KUSTOMIZE) build third_party/open-policy-agent/gatekeeper/helmify | go run third_party/open-policy-agent/gatekeeper/helmify/*.go

	@sed -i -e "s/AZURE_TENANT_ID: .*/AZURE_TENANT_ID: <replace with Azure Tenant ID>/" manifest_staging/deploy/azure-wi-webhook.yaml
	@sed -i -e "s/AZURE_ENVIRONMENT: .*/AZURE_ENVIRONMENT: <replace with Azure Environment Name>/" manifest_staging/deploy/azure-wi-webhook.yaml
	@sed -i -e "s/-arc-cluster=.*/-arc-cluster=false/" manifest_staging/deploy/azure-wi-webhook.yaml

# Generate code
.PHONY: generate
generate: $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

## --------------------------------------
## Tooling Binaries and Manifests
## --------------------------------------

$(CONTROLLER_GEN):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/controller-tools/cmd/controller-gen $(CONTROLLER_GEN_BIN) $(CONTROLLER_GEN_VER)

$(GINKGO):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/onsi/ginkgo/ginkgo $(GINKGO_BIN) $(GINKGO_VER)

$(KIND):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/kind $(KIND_BIN) $(KIND_VER)

$(KUSTOMIZE):
	mkdir -p $(TOOLS_BIN_DIR)
	rm -rf "$(SHELLCHECK)*"
	curl -sfOL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$(KUSTOMIZE_VER)/kustomize_$(KUSTOMIZE_VER)_$(GOOS)_$(GOARCH).tar.gz"
	tar xf kustomize_${KUSTOMIZE_VER}_$(GOOS)_$(GOARCH).tar.gz
	cp "kustomize" "$(KUSTOMIZE)"
	ln -sf "$(KUSTOMIZE)" "$(TOOLS_BIN_DIR)/$(KUSTOMIZE_BIN)"
	chmod +x "$(TOOLS_BIN_DIR)/$(KUSTOMIZE_BIN)" "$(KUSTOMIZE)"
	rm -rf kustomize*

$(KUBECTL):
	mkdir -p $(TOOLS_BIN_DIR)
	rm -f "$(KUBECTL)*"
	curl -sfL https://storage.googleapis.com/kubernetes-release/release/$(KUBECTL_VER)/bin/$(GOOS)/$(GOARCH)/kubectl -o $(KUBECTL)
	ln -sf "$(KUBECTL)" "$(TOOLS_BIN_DIR)/$(KUBECTL_BIN)"
	chmod +x "$(TOOLS_BIN_DIR)/$(KUBECTL_BIN)" "$(KUBECTL)"

$(GOLANGCI_LINT):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/golangci/golangci-lint/cmd/golangci-lint $(GOLANGCI_LINT_BIN) $(GOLANGCI_LINT_VER)

$(SHELLCHECK): OS := $(shell uname | tr '[:upper:]' '[:lower:]')
$(SHELLCHECK): ARCH := $(shell uname -m)
$(SHELLCHECK):
	mkdir -p $(TOOLS_BIN_DIR)
	rm -rf "$(SHELLCHECK)*"
	curl -sfOL "https://github.com/koalaman/shellcheck/releases/download/$(SHELLCHECK_VER)/shellcheck-$(SHELLCHECK_VER).$(OS).$(ARCH).tar.xz"
	tar xf shellcheck-$(SHELLCHECK_VER).$(OS).$(ARCH).tar.xz
	cp "shellcheck-$(SHELLCHECK_VER)/$(SHELLCHECK_BIN)" "$(SHELLCHECK)"
	ln -sf "$(SHELLCHECK)" "$(TOOLS_BIN_DIR)/$(SHELLCHECK_BIN)"
	chmod +x "$(TOOLS_BIN_DIR)/$(SHELLCHECK_BIN)" "$(SHELLCHECK)"
	rm -rf shellcheck*

$(ENVSUBST):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/a8m/envsubst/cmd/envsubst $(ENVSUBST_BIN) $(ENVSUBST_VER)

$(HELM): OS := $(shell uname | tr '[:upper:]' '[:lower:]')
$(HELM):
	curl -sfOL "https://get.helm.sh/helm-$(HELM_VER)-$(GOOS)-$(GOARCH).tar.gz"
	tar -zxvf helm-$(HELM_VER)-$(GOOS)-$(GOARCH).tar.gz
	cp "$(OS)-$(GOARCH)/$(HELM_BIN)" "$(HELM)"
	ln -sf "$(HELM)" "$(TOOLS_BIN_DIR)/$(HELM_BIN)"
	chmod +x "$(TOOLS_BIN_DIR)/$(HELM_BIN)" "$(HELM)"
	rm -rf helm* $(OS)-$(GOARCH)

## --------------------------------------
## E2E images
## --------------------------------------
MSAL_GO_E2E_IMAGE_NAME := msal-go-e2e
MSAL_GO_E2E_IMAGE := $(REGISTRY)/$(MSAL_GO_E2E_IMAGE_NAME):$(IMAGE_VERSION)

.PHONY: docker-build-e2e-msal-go
docker-build-e2e-msal-go:
	docker buildx build --no-cache -t $(MSAL_GO_E2E_IMAGE) -f examples/msal-go/Dockerfile --platform="linux/amd64" --output=$(OUTPUT_TYPE) examples/msal-go
	touch .image-$(MSAL_GO_E2E_IMAGE_NAME)-amd64

## --------------------------------------
## Testing
## --------------------------------------

# Run go fmt against code
.PHONY: fmt
fmt:
	go fmt ./...

# Run go vet against code
.PHONY: vet
vet:
	go vet ./...

# Run tests
.PHONY: test
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out

$(E2E_TEST):
	go test -tags=e2e -c ./test/e2e -o $(E2E_TEST)

# Ginkgo configurations
GINKGO_FOCUS ?=
GINKGO_SKIP ?=
GINKGO_NODES ?= 3
GINKGO_NO_COLOR ?= false
GINKGO_TIMEOUT ?= 5m
GINKGO_ARGS ?= -focus="$(GINKGO_FOCUS)" -skip="$(GINKGO_SKIP)" -nodes=$(GINKGO_NODES) -noColor=$(GINKGO_NO_COLOR) -timeout=$(GINKGO_TIMEOUT)

# E2E configurations
KUBECONFIG ?= $(HOME)/.kube/config
E2E_ARGS := -kubeconfig=$(KUBECONFIG) -report-dir=$(PWD)/_artifacts \
				 -e2e.arc-cluster=$(ARC_CLUSTER) \
				 -e2e.token-exchange-image=$(MSAL_GO_E2E_IMAGE) \
				 -e2e.proxy-image=$(PROXY_IMAGE) \
				 -e2e.proxy-init-image=$(INIT_IMAGE)
E2E_EXTRA_ARGS ?=

.PHONY: test-e2e-run
test-e2e-run: $(E2E_TEST) $(GINKGO)
	$(GINKGO) -v -trace $(GINKGO_ARGS) \
		$(E2E_TEST) -- $(E2E_ARGS) $(E2E_EXTRA_ARGS)

.PHONY: test-e2e
test-e2e: $(KUBECTL) $(HELM)
	./scripts/ci-e2e.sh

## --------------------------------------
## Kind
## --------------------------------------

KIND_CLUSTER_NAME ?= azure-workload-identity

.PHONY: kind-create
kind-create: $(KIND) $(KUBECTL)
	./scripts/create-kind-cluster.sh

.PHONY: kind-load-images
kind-load-images:
	-[ -f .image-$(WEBHOOK_IMAGE_NAME)-amd64 ] && $(KIND) load docker-image $(WEBHOOK_IMAGE) --name $(KIND_CLUSTER_NAME)
	-[ -f .image-$(PROXY_IMAGE_NAME)-amd64 ] && $(KIND) load docker-image $(PROXY_IMAGE) --name $(KIND_CLUSTER_NAME)
	-[ -f .image-$(INIT_IMAGE_NAME)-amd64 ] && $(KIND) load docker-image $(INIT_IMAGE) --name $(KIND_CLUSTER_NAME)
	-[ -f .image-$(MSAL_GO_E2E_IMAGE_NAME)-amd64 ] && $(KIND) load docker-image $(MSAL_GO_E2E_IMAGE) --name $(KIND_CLUSTER_NAME)

.PHONY: kind-delete
kind-delete: $(KIND)
	$(KIND) delete cluster --name=$(KIND_CLUSTER_NAME) || true

## --------------------------------------
## Cleanup
## --------------------------------------

.PHONY: clean
clean:
	@rm -rf $(BIN_DIR)
	@rm -rf .image-*

## --------------------------------------
## Linting
## --------------------------------------

.PHONY: lint
lint: $(GOLANGCI_LINT)
	$(GOLANGCI_LINT) run -v

.PHONY: helm-lint
helm-lint: $(HELM)
	$(HELM) lint manifest_staging/charts/workload-identity-webhook

.PHONY: lint-full
lint-full: $(GOLANGCI_LINT) ## Run slower linters to detect possible issues
	$(GOLANGCI_LINT) run -v --fast=false

.PHONY: shellcheck
shellcheck: $(SHELLCHECK)
	$(SHELLCHECK) */*.sh

## --------------------------------------
## Release
## --------------------------------------

release-manifest: $(KUSTOMIZE)
	@sed -i -e 's/^IMAGE_VERSION ?= .*/IMAGE_VERSION ?= ${NEW_VERSION}/' ./Makefile
	cd config/manager && $(KUSTOMIZE) edit set image manager=$(REGISTRY)/$(WEBHOOK_IMAGE_NAME):$(NEW_VERSION)
	@sed -i -e "s/appVersion: .*/appVersion: ${NEW_VERSION}/" ./third_party/open-policy-agent/gatekeeper/helmify/static/Chart.yaml
	@sed -i -e "s/version: .*/version: $$(echo ${NEW_VERSION} | cut -c2-)/" ./third_party/open-policy-agent/gatekeeper/helmify/static/Chart.yaml
	@sed -i -e "s/release: .*/release: ${NEW_VERSION}/" ./third_party/open-policy-agent/gatekeeper/helmify/static/values.yaml
	@sed -i -e 's/Current release version: `.*`/Current release version: `'"${NEW_VERSION}"'`/' ./third_party/open-policy-agent/gatekeeper/helmify/static/README.md
	export
	$(MAKE) manifests

.PHONY: promote-staging-manifest
promote-staging-manifest: #promote staging manifests to release dir
	@rm -rf deploy
	@cp -r manifest_staging/deploy .
	@rm -rf charts/workload-identity-webhook
	@cp -r manifest_staging/charts .