SHELL := /bin/bash
MAKEFLAGS += --warn-undefined-variables
.ONESHELL:
.DEFAULT_GOAL := help

TF ?= terraform
TF_PLAN ?= tfplan.out
TF_VAR_FILE ?= terraform.tfvars

PLAN_ARGS ?=
APPLY_ARGS ?=
DESTROY_ARGS ?=
REFRESH_ARGS ?=
INIT_ARGS ?=

export TF_IN_AUTOMATION = 1
export TF_INPUT = 0

.PHONY: help init fmt validate plan apply plan-destroy destroy refresh-state state-pull clean

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*##"} {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Initialize Terraform backend and providers
	$(TF) init $(INIT_ARGS)

fmt: ## Format Terraform configuration
	$(TF) fmt -recursive

validate: init ## Validate configuration
	$(TF) validate

plan: init validate ## Generate and store execution plan
	$(TF) plan -out=$(TF_PLAN) $(PLAN_ARGS)

apply: init ## Apply configuration (uses stored plan when present)
	if [ -f "$(TF_PLAN)" ]; then \
		$(TF) apply $(APPLY_ARGS) "$(TF_PLAN)"; \
	else \
		$(TF) apply $(APPLY_ARGS); \
	fi

plan-destroy: init ## Create destroy plan without applying it
	$(TF) plan -destroy $(PLAN_ARGS)

destroy: init ## Destroy managed infrastructure
	$(TF) destroy $(DESTROY_ARGS)

refresh-state: init ## Refresh state to match real infrastructure
	$(TF) apply -refresh-only -auto-approve $(REFRESH_ARGS)

state-pull: init ## Pull current state to terraform.tfstate
	$(TF) state pull > terraform.tfstate

clean: ## Remove cached plan artifact
	rm -f "$(TF_PLAN)"
