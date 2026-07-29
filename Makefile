.DEFAULT_GOAL := help
SHELL := /bin/bash

TF := terraform
TF_DIR := terraform
BOOTSTRAP_DIR := terraform/bootstrap

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- python -------------------------------------------------------------------

.PHONY: install
install: ## Install dev dependencies
	python -m pip install -r requirements-dev.txt

.PHONY: lint
lint: ## Lint and format-check the Lambda source
	python -m ruff check lambdas tests
	python -m ruff format --check lambdas tests

.PHONY: fix
fix: ## Auto-fix lint and formatting
	python -m ruff check --fix lambdas tests
	python -m ruff format lambdas tests

.PHONY: typecheck
typecheck: ## Type-check the Lambda source
	python -m mypy lambdas

.PHONY: test
test: ## Run the unit tests
	python -m pytest

.PHONY: coverage
coverage: ## Run tests with a coverage report
	python -m pytest --cov=lambdas --cov-report=term-missing

# --- terraform ----------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## Create the Terraform state bucket (run once, by hand)
	cd $(BOOTSTRAP_DIR) && $(TF) init && $(TF) apply

.PHONY: init
init: ## terraform init against the remote backend (needs backend.hcl)
	cd $(TF_DIR) && $(TF) init -backend-config=backend.hcl

.PHONY: fmt
fmt: ## Rewrite Terraform files into canonical format
	$(TF) fmt -recursive

.PHONY: validate
validate: ## Validate Terraform without touching the backend
	cd $(TF_DIR) && $(TF) init -backend=false -input=false && $(TF) validate

.PHONY: plan
plan: ## Show what would change
	cd $(TF_DIR) && $(TF) plan -input=false

.PHONY: apply
apply: ## Apply the stack (prompts for confirmation)
	cd $(TF_DIR) && $(TF) apply -input=false

.PHONY: outputs
outputs: ## Print stack outputs
	cd $(TF_DIR) && $(TF) output

.PHONY: nameservers
nameservers: ## Print the NS records to set at your registrar
	@cd $(TF_DIR) && $(TF) output -json nameservers | tr -d '[]"' | tr ',' '\n'

# --- combined -----------------------------------------------------------------

.PHONY: check
check: lint typecheck test fmt-check validate ## Everything CI runs

.PHONY: fmt-check
fmt-check:
	$(TF) fmt -check -recursive -diff

.PHONY: clean
clean: ## Remove build and cache artifacts
	rm -rf $(TF_DIR)/build .pytest_cache .mypy_cache .ruff_cache .coverage coverage.xml htmlcov
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

.PHONY: security
security: ## Run the scans CI runs
	checkov --config-file .checkov.yaml
	pip-audit -r requirements-dev.txt --progress-spinner off
	git ls-files | xargs detect-secrets-hook --baseline .secrets.baseline

.PHONY: secrets-baseline
secrets-baseline: ## Regenerate the detect-secrets baseline after auditing findings
	detect-secrets scan --exclude-files '\.terraform/|terraform/build/|\.git/' \
		> .secrets.baseline
