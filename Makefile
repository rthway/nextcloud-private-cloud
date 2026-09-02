# ---------------------------------------------------------------------------
# Operator interface.
#
# Every target here is a command that is otherwise easy to get subtly wrong --
# the right compose file combination, the right flags, the right order. If a
# procedure is worth documenting it is worth making executable, because a
# documented command drifts from reality and a Makefile target does not.
#
#   make help    lists everything
# ---------------------------------------------------------------------------

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Compose file combinations. Observability is opt-in because it roughly
# doubles the memory footprint and most day-to-day work does not need it.
COMPOSE      := docker compose
COMPOSE_OBS  := docker compose -f compose.yml -f compose.observability.yml
COMPOSE_PROD := docker compose -f compose.yml -f compose.prod.yml

# Stamped into image labels so a running container can be traced to a commit.
export BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
export VCS_REF    := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

.PHONY: help
help: ## Show this help
	@printf '\nNextcloud private cloud\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

# --- Bootstrap -------------------------------------------------------------

.PHONY: setup
setup: ## First-run: create .env, generate secrets and a local certificate
	@./scripts/gen-secrets.sh
	@./scripts/gen-local-tls.sh
	@printf '\nReady. Next: make up\n\n'

.PHONY: occ
occ: ## Run an occ command: make occ ARGS="user:list"
	@./scripts/occ.sh $(ARGS)

.PHONY: scan
scan: ## Reconcile the file index with what is actually on disk
	@./scripts/occ.sh files:scan --all

.PHONY: nc-check
nc-check: ## Nextcloud's own configuration checks
	@./scripts/occ.sh check
	@./scripts/occ.sh db:add-missing-indices
	@./scripts/occ.sh db:add-missing-columns

# --- Lifecycle -------------------------------------------------------------

.PHONY: up
up: ## Start the stack (build if needed)
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory wait

.PHONY: up-obs
up-obs: ## Start the stack with Prometheus, Grafana and Loki
	$(COMPOSE_OBS) up -d --build
	@$(MAKE) --no-print-directory wait

.PHONY: down
down: ## Stop the stack, keeping all data
	$(COMPOSE_OBS) down

.PHONY: destroy
destroy: ## Stop the stack AND DELETE ALL DATA (database, user files)
	@printf '\nThis deletes the database and every user file permanently.\n'
	@read -p 'Type DESTROY to confirm: ' c; [[ "$$c" == "DESTROY" ]] || { echo "aborted"; exit 1; }
	$(COMPOSE_OBS) down --volumes

.PHONY: restart
restart: ## Restart application containers without touching the database
	$(COMPOSE) restart app cron proxy

.PHONY: wait
wait: ## Block until every service reports healthy
	@printf 'waiting for services to become healthy'
	@for i in $$(seq 1 60); do \
		unhealthy=$$($(COMPOSE) ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
			| awk '$$2 != "healthy" && $$2 != "" {print $$1}' | tr '\n' ' '); \
		if [[ -z "$$unhealthy" ]]; then printf '\nall services healthy\n'; exit 0; fi; \
		printf '.'; sleep 3; \
	done; \
	printf '\nstill not healthy: %s\n' "$$unhealthy"; \
	$(COMPOSE) ps; exit 1

# --- Observation -----------------------------------------------------------

.PHONY: ps
ps: ## Show container status
	@$(COMPOSE_OBS) ps

.PHONY: logs
logs: ## Follow logs from all services
	$(COMPOSE) logs -f --tail=100

.PHONY: logs-app
logs-app: ## Follow Nextcloud logs only
	$(COMPOSE) logs -f --tail=100 app

.PHONY: health
health: ## Run the full stack health check
	@./scripts/healthcheck.sh

.PHONY: shell
shell: ## Open a shell in the Nextcloud container
	$(COMPOSE) exec app sh

.PHONY: db-shell
db-shell: ## Open a MariaDB shell
	@set -a; source .env; set +a; \
	$(COMPOSE) exec -e MYSQL_PWD="$$MYSQL_PASSWORD" db \
		mariadb -u "$$MYSQL_USER" "$$MYSQL_DATABASE"

# --- Data ------------------------------------------------------------------

.PHONY: backup
backup: ## Take a full backup (database + files + config) and apply retention
	@./scripts/backup.sh

.PHONY: verify-backup
verify-backup: ## Prove the newest backup restores into a scratch database
	@./scripts/verify-backup.sh

.PHONY: restore
restore: ## Restore a backup: make restore BACKUP=20260902T054616Z
	@[[ -n "$(BACKUP)" ]] || { echo "usage: make restore BACKUP=<id>"; \
		echo "available:"; ls -1 backups 2>/dev/null | sed 's/^/  /'; exit 2; }
	@./scripts/restore.sh $(BACKUP)

.PHONY: backups
backups: ## List backups and whether each has been verified
	@printf '%-20s %-10s %s\n' 'BACKUP' 'SIZE' 'VERIFIED'
	@for d in backups/*/; do \
		[[ -d "$$d" ]] || continue; \
		id=$$(basename "$$d"); \
		size=$$(du -sh "$$d" | cut -f1); \
		v=$$(grep -q '"verified": true' "$$d/manifest.json" 2>/dev/null && echo yes || echo 'NO'); \
		printf '%-20s %-10s %s\n' "$$id" "$$size" "$$v"; \
	done

# --- Quality gates ---------------------------------------------------------

.PHONY: test
test: ## Run the full test suite
	@./tests/run-all.sh

.PHONY: lint
lint: ## Lint shell scripts, Dockerfile and YAML
	@./tests/test-lint.sh

.PHONY: validate
validate: ## Validate compose, nginx and PHP configuration without starting
	@./tests/test-config.sh

.PHONY: smoke
smoke: ## Run smoke tests against the running stack
	@./tests/test-smoke.sh

.PHONY: security
security: ## Scan the filesystem and built image for vulnerabilities and secrets
	@./tests/test-security.sh

# --- Build -----------------------------------------------------------------

.PHONY: build
build: ## Build the Nextcloud image
	$(COMPOSE) build

.PHONY: pull
pull: ## Pull updated base images
	$(COMPOSE_OBS) pull

.PHONY: config
config: ## Print the fully resolved compose configuration
	@$(COMPOSE) config

.PHONY: clean
clean: ## Remove dangling images and build cache (keeps volumes)
	docker image prune -f
	docker builder prune -f
