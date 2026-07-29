.PHONY: help sync status dispatch bootstrap setup lint test evidence learnings learnings-stats preamble review autoplan retro paperclip-up paperclip-down paperclip-status paperclip-refresh paperclip-sync paperclip-check paperclip-safe-defaults paperclip-agent-status paperclip-agent-on paperclip-agent-off fleet-status scorecard

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

test: ## Ground Truth unit tests (launchers, failover, routing, autoplan fail-closed)
	@echo "== launcher contract =="
	@./tests/run-launcher-tests.sh
	@echo ""
	@echo "== failover =="
	@./tests/run-failover-tests.sh
	@echo ""
	@echo "== routing + effective_model =="
	@./tests/run-routing-tests.sh
	@echo ""
	@echo "== autoplan fail-closed =="
	@./tests/run-autoplan-failclosed-tests.sh
	@echo ""
	@echo "== evidence scorecard =="
	@./tests/run-evidence-tests.sh
	@echo ""
	@echo "All test suites passed."

paperclip-up: ## Start local Paperclip (idempotent — installs first run, starts subsequently)
	@./scripts/paperclip-up.sh

paperclip-down: ## Stop local Paperclip server cleanly
	@./scripts/paperclip-down.sh

paperclip-status: ## Show Paperclip health, version, and instance dir
	@./scripts/paperclip-status.sh

paperclip-refresh: ## Fetch latest Paperclip releases, append to learnings/paperclip-changelog.md
	@./scripts/paperclip-refresh.sh

paperclip-sync: ## Sync providers/claude/agents/ → live Paperclip AGENTS.md (apply mode)
	@./scripts/paperclip-sync.sh --apply

paperclip-check: ## Report drift between providers/ and live Paperclip agents (check mode)
	@./scripts/paperclip-sync.sh --check

paperclip-safe-defaults: ## Re-apply cost-safe defaults (heartbeat=OFF + budget caps) to all agents
	@./scripts/paperclip-apply-safe-defaults.sh

paperclip-agent-status: ## Show heartbeat + budget state per agent (use STATUS_FLAGS=--recent for last-seen)
	@./scripts/paperclip-agent.sh status $(STATUS_FLAGS)

paperclip-agent-on: ## Enable heartbeat for one agent (usage: make paperclip-agent-on AGENT="Frontend Engineer")
	@./scripts/paperclip-agent.sh on "$(AGENT)"

paperclip-agent-off: ## Disable heartbeat for one agent (usage: make paperclip-agent-off AGENT="Frontend Engineer")
	@./scripts/paperclip-agent.sh off "$(AGENT)"

fleet-status: ## Unified dashboard: Paperclip agents, heartbeat states, local Ollama, Sentinel activity (the single command you want)
	@./scripts/fleet-status.sh

scorecard: ## Cross-vendor provider scorecard: cooldown state, rate-cap events, per-provider task outcomes
	@./scripts/provider-scorecard.sh

evidence: ## Fleet Evidence Scorecard (handoffs + ab-metrics → tables + logs/evidence.csv)
	@./scripts/wave-report.sh

local-sentinel: ## Run the local (zero-cost) PR Sentinel once (uses olympus-coder via Ollama)
	@./scripts/local-pr-sentinel.sh

local-sentinel-dry: ## Dry-run the local PR Sentinel (see what it would do without filing anything)
	@./scripts/local-pr-sentinel.sh --dry-run

local-sentinel-install: ## Install the Local PR Sentinel as a background macOS service (launchd, every 30 min)
	@./scripts/local-sentinel-install.sh

local-sentinel-uninstall: ## Remove the background service
	@./scripts/local-sentinel-uninstall.sh

local-sentinel-status: ## Check if the launchd service is loaded
	@launchctl list | grep -E 'local-pr-sentinel|PID' || echo "Service not loaded"

local-sentinel-logs: ## Tail the local sentinel log file
	@tail -f ~/Library/Logs/local-pr-sentinel.log
