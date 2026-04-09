.PHONY: help sync status dispatch bootstrap setup lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

sync: ## Sync roles/ to provider directories
	@./scripts/sync-providers.sh

status: ## Check worker fleet status
	@./scripts/workers-status.sh

dispatch: ## Dispatch wave plan (usage: make dispatch REPO=x PLAN=y)
	@./scripts/dispatch.sh $(REPO) $(PLAN)

bootstrap: ## Install agents locally (usage: make bootstrap PROVIDER=claude)
	@./scripts/bootstrap.sh $(or $(PROVIDER),claude)

setup: ## Run machine setup
	@./scripts/setup-machine.sh

lint: ## Check sync + validate YAML
	@echo "Checking roles/ vs providers/ sync..."
	@./scripts/sync-providers.sh --check
	@echo ""
	@echo "Validating workers.yaml structure..."
	@grep -q "machines:" config/workers.yaml && echo "  workers.yaml: OK" || (echo "  workers.yaml: MISSING machines: key" && exit 1)
