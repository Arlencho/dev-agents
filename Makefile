.PHONY: help sync status dispatch bootstrap setup lint learnings learnings-stats preamble review autoplan retro paperclip-up paperclip-down paperclip-status paperclip-refresh

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

notify: ## Test notification (usage: make notify AGENT=go-backend WORKER=mac-mini-1 BRANCH=feat/test STATUS=success)
	@./scripts/notify.sh $(AGENT) $(WORKER) $(BRANCH) $(STATUS)

learnings: ## Query learnings (usage: make learnings PROJECT=x)
	@./scripts/learnings.sh query $(PROJECT)

learnings-stats: ## Show learnings stats across all projects
	@./scripts/learnings.sh stats

preamble: ## Generate preamble for a project (usage: make preamble REPO=/path AGENT=go-backend BRANCH=feat/x)
	@./scripts/preamble.sh $(REPO) $(AGENT) $(BRANCH)

review: ## Run full review wave (usage: make review REPO=url BRANCH=x)
	@sed "s/BRANCH/$(BRANCH)/g" templates/review-wave.txt > /tmp/review-plan.txt
	@./scripts/dispatch.sh $(REPO) /tmp/review-plan.txt

autoplan: ## Review a plan before dispatch (usage: make autoplan PLAN=path)
	@./scripts/autoplan.sh $(PLAN)

retro: ## Run retrospective (usage: make retro PROJECT=x)
	@./scripts/retro-data.sh $(PROJECT) | cat

lint: ## Check sync + validate YAML
	@echo "Checking roles/ vs providers/ sync..."
	@./scripts/sync-providers.sh --check
	@echo ""
	@echo "Validating workers.yaml structure..."
	@grep -q "machines:" config/workers.yaml && echo "  workers.yaml: OK" || (echo "  workers.yaml: MISSING machines: key" && exit 1)

paperclip-up: ## Start local Paperclip (idempotent — installs first run, starts subsequently)
	@./scripts/paperclip-up.sh

paperclip-down: ## Stop local Paperclip server cleanly
	@./scripts/paperclip-down.sh

paperclip-status: ## Show Paperclip health, version, and instance dir
	@./scripts/paperclip-status.sh

paperclip-refresh: ## Fetch latest Paperclip releases, append to learnings/paperclip-changelog.md
	@./scripts/paperclip-refresh.sh
