# Local development shortcuts. CI does not use this file - it runs the same
# commands directly so there is no divergence between the two.

.DEFAULT_GOAL := help
SHELL := /bin/bash

PG_CONTAINER := migration-tracker-pg
PG_PORT      := 55440
TEST_DB_URL  := postgresql+psycopg://postgres:postgres@localhost:$(PG_PORT)/migration_tracker_test

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install all dependencies
	uv sync --all-groups

.PHONY: lint
lint: ## Run ruff and mypy
	uv run ruff check .
	uv run ruff format --check .
	uv run mypy app

.PHONY: fmt
fmt: ## Auto-format
	uv run ruff format .
	uv run ruff check --fix .

.PHONY: db-up
db-up: ## Start the local test database
	@docker rm -f $(PG_CONTAINER) >/dev/null 2>&1 || true
	docker run -d --name $(PG_CONTAINER) \
	  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
	  -e POSTGRES_DB=migration_tracker_test \
	  -p $(PG_PORT):5432 postgres:17-alpine
	@echo "waiting for postgres..."
	@for i in $$(seq 1 30); do \
	  docker exec $(PG_CONTAINER) pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
	@echo "ready on port $(PG_PORT)"

.PHONY: db-down
db-down: ## Stop the local test database
	@docker rm -f $(PG_CONTAINER) >/dev/null 2>&1 || true

.PHONY: test-unit
test-unit: ## Run unit tests
	uv run pytest tests/unit -v

.PHONY: test-integration
test-integration: ## Run integration tests (needs db-up)
	TEST_DATABASE_URL=$(TEST_DB_URL) uv run pytest tests/integration -v

.PHONY: test
test: ## Run everything with combined coverage and the 80% gate
	@rm -f .coverage .coverage.unit .coverage.integration coverage.xml
	COVERAGE_FILE=.coverage.unit uv run pytest tests/unit --cov=app --cov-report=
	TEST_DATABASE_URL=$(TEST_DB_URL) COVERAGE_FILE=.coverage.integration \
	  uv run pytest tests/integration --cov=app --cov-report=
	uv run coverage combine .coverage.unit .coverage.integration
	uv run coverage xml -o coverage.xml
	uv run coverage report
	uv run python scripts/coverage_gate.py --report coverage.xml --min 80

.PHONY: build
build: ## Build the container image
	docker build -t migration-tracker:local --build-arg GIT_SHA=$$(git rev-parse --short HEAD) .

.PHONY: run
run: ## Run the stack locally
	docker compose up --build

.PHONY: tf-validate
tf-validate: ## Validate and format-check every Terraform stack
	@terraform fmt -check -recursive terraform/
	@for d in terraform/modules/*/ terraform/envs/*/ terraform/bootstrap/; do \
	  [ -f "$$d/main.tf" ] || continue; \
	  printf '%-40s' "$$d"; \
	  (cd "$$d" && terraform init -backend=false -input=false >/dev/null 2>&1 && \
	    terraform validate -no-color | head -1); \
	done

.PHONY: k8s-validate
k8s-validate: ## Render both kustomize overlays
	@for o in staging prod; do \
	  printf '%-10s' "$$o"; \
	  kubectl kustomize deploy/k8s/overlays/$$o >/dev/null && echo "ok"; \
	done

.PHONY: ci-local
ci-local: lint tf-validate k8s-validate test ## Run everything CI runs

.PHONY: workflows
workflows: ## Lint the GitHub Actions workflows
	actionlint -no-color
