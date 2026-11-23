SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENVS        := staging prod
TF_DIRS     := $(wildcard terraform/modules/*) $(addprefix terraform/envs/,$(ENVS)) terraform/bootstrap
APP_DIR     := apps/demo-api
IMAGE       ?= demo-api:dev

.PHONY: help
help: ## Show targets
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

## ---------- aggregate ----------
.PHONY: validate
validate: tf-fmt tf-validate tf-lint tf-test tf-scan helm-validate helm-scan go-test ## Run every offline check CI runs

## ---------- terraform ----------
.PHONY: tf-fmt
tf-fmt: ## terraform fmt -check
	terraform fmt -check -recursive -diff terraform

.PHONY: tf-validate
tf-validate: ## terraform init -backend=false + validate for every module/env
	@for d in $(TF_DIRS); do \
	  echo "==> validate $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  terraform -chdir=$$d validate -no-color; \
	done

.PHONY: tf-lint
tf-lint: ## tflint (aws ruleset) across all modules/envs
	tflint --init --config "$(CURDIR)/.tflint.hcl"
	tflint --config "$(CURDIR)/.tflint.hcl" --recursive --chdir terraform --format compact

.PHONY: tf-test
tf-test: ## terraform test with mocked AWS provider (offline plan of every env)
	@for d in terraform/modules/vpc $(addprefix terraform/envs/,$(ENVS)); do \
	  echo "==> test $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  terraform -chdir=$$d test -no-color; \
	done

.PHONY: tf-scan
tf-scan: ## trivy misconfiguration scan (MEDIUM and above fail the build)
	trivy config --exit-code 1 --severity MEDIUM,HIGH,CRITICAL terraform

## ---------- helm ----------
.PHONY: helm-validate
helm-validate: ## helm lint + helm template | kubeconform for all value sets
	./scripts/validate-chart.sh

.PHONY: helm-scan
helm-scan: ## trivy misconfiguration scan of the chart (HIGH/CRITICAL fail)
	trivy config --exit-code 1 --severity HIGH,CRITICAL charts/service

## ---------- app ----------
.PHONY: go-test
go-test: ## go vet + race tests for demo-api
	cd $(APP_DIR) && go vet ./... && go test -race -count=1 ./...

.PHONY: docker-build
docker-build: ## Build the distroless demo-api image
	docker build -t $(IMAGE) $(APP_DIR)

.PHONY: image-scan
image-scan: docker-build ## trivy vulnerability scan of the image (HIGH/CRITICAL fail)
	trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed $(IMAGE)

## ---------- local kind ----------
.PHONY: local-up
local-up: ## Create kind cluster, install kube-prometheus-stack, deploy demo-api via the chart
	./local/up.sh

.PHONY: local-test
local-test: ## helm test + curl the API + assert Prometheus is scraping it
	./local/test.sh

.PHONY: local-down
local-down: ## Delete the kind cluster
	./local/down.sh
