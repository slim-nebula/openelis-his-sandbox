# =============================================================================
# OpenELIS <-> HIS sandbox
#
#   make up          bring everything up in the right order
#   make provision   stamp LOINC codes onto the OpenELIS test catalogue
#   make smoke       platform smoke test   (brief phase 1)
#   make e2e         order flow test       (brief phase 2/3)
#   make results     result return path
#   make rejection   LIS rejection round trip
#   make negative    negative-path test    (brief phase 4)
#   make down        stop applications, keep data
#   make clean       destroy everything including volumes
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENVFILE := --env-file .env
DATA    := docker compose -p his-lab-data $(ENVFILE) -f compose/data.yml
APP     := docker compose -p his-lab-sandbox $(ENVFILE) \
             -f compose/platform.yml -f compose/apps.yml -f compose/openelis.yml

include .env
export

.PHONY: help config data-up app-up up provision down clean logs ps \
        smoke e2e results rejection negative capture migrate psql-his psql-oe topics urls

help:
	@grep -hE '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	 awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

config: ## Render templated configuration from .env
	@bash scripts/render-config.sh

data-up: ## Start the external database servers
	@echo "==> Starting external database servers"
	@$(DATA) up -d
	@bash scripts/wait-for.sh "HIS database" \
	  "docker exec his-db-external pg_isready -q -U $(HIS_DB_ADMIN_USER) -d $(HIS_DB_NAME)" 120
	@bash scripts/wait-for.sh "OpenELIS database" \
	  "docker exec openelis-db-external pg_isready -q -U $(OE_DB_USER) -d $(OE_DB_NAME)" 300

app-up: ## Start platform, applications and OpenELIS
	@echo "==> Building and starting the sandbox"
	@$(APP) up -d --build
	@# Kong caches upstream DNS for the record's TTL. If his-api was recreated
	@# while Kong kept running, Kong can hold an IP that now belongs to another
	@# container. Restarting it after the stack settles makes `up` repeatable.
	@echo "==> Refreshing Kong's upstream DNS"
	@$(APP) restart kong >/dev/null

up: config data-up app-up ## Full startup
	@echo ""
	@$(MAKE) --no-print-directory urls

migrate: ## Apply any unapplied schema migrations to a running database
	@bash scripts/migrate.sh

provision: ## Disambiguate the OpenELIS test catalogue (restarts the webapp)
	@echo "==> Provisioning OpenELIS test catalogue"
	@docker exec -i -e PGPASSWORD=$(OE_DB_PASSWORD) openelis-db-external \
	  psql -U $(OE_DB_USER) -d $(OE_DB_NAME) \
	  < openelis/provision/01-loinc-mapping.sql
	@echo "==> Restarting OpenELIS (sample-type bindings are cached in memory)"
	@docker restart openelis-webapp >/dev/null
	@bash scripts/wait-for.sh "OpenELIS webapp" \
	  "curl -skf -o /dev/null https://localhost/api/OpenELIS-Global/LoginPage" 300 \
	  || echo "    (webapp still starting; give it another minute)"

down: ## Stop applications (databases keep running)
	@$(APP) down

clean: ## Destroy everything, including database volumes
	@$(APP) down -v --remove-orphans || true
	@$(DATA) down -v --remove-orphans || true
	@docker network rm oe-data-net 2>/dev/null || true

logs: ## Tail logs (make logs S=bridge)
	@$(APP) logs -f --tail=120 $(S)

ps: ## Show container status
	@$(DATA) ps
	@$(APP) ps

urls: ## Print the entry points
	@echo "  HIS sandbox frontend   http://localhost:$(EDGE_HTTP_PORT)"
	@echo "  HIS API (via Kong)     http://localhost:$(EDGE_HTTP_PORT)/api/healthz"
	@echo "  Kong admin             http://localhost:$(KONG_ADMIN_PORT)"
	@echo "  OpenELIS UI            https://localhost:$(OE_UI_HTTPS_PORT)   (admin / $(OE_DEFAULT_PASSWORD))"
	@echo "  Bridge FHIR endpoint   docker exec bridge curl -s http://localhost:8080/fhir/metadata"
	@echo "  HIS database           psql -h localhost -p $(HIS_DB_PUBLISHED_PORT) -U $(HIS_DB_USER) -d $(HIS_DB_NAME)"
	@echo "  OpenELIS database      psql -h localhost -p $(OE_DB_PUBLISHED_PORT) -U $(OE_DB_USER) -d $(OE_DB_NAME)"

smoke: ## Phase 1 - platform smoke test
	@bash scripts/test-smoke.sh

e2e: ## Phase 2/3 - order flow through to OpenELIS
	@bash scripts/test-order-flow.sh

results: ## Result return path - bridge correlation and HIS projection
	@bash scripts/test-result-return.sh

rejection: ## LIS rejection round trip - catalogue drift
	@bash scripts/test-rejection.sh

corrections: ## Corrections and retractions of an already-released result
	@bash scripts/test-corrections.sh $(ORDER)

capture: ## Capture what OpenELIS really sends on release (needs a lab user)
	@bash scripts/capture-lis-result.sh $(ORDER)

negative: ## Phase 4 - negative paths
	@bash scripts/test-negative.sh

topics: ## List Kafka topics
	@docker exec his-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list

psql-his: ## Open psql on the HIS sandbox database
	@docker exec -it -e PGPASSWORD=$(HIS_DB_PASSWORD) his-db-external \
	  psql -U $(HIS_DB_USER) -d $(HIS_DB_NAME)

psql-oe: ## Open psql on the OpenELIS database
	@docker exec -it -e PGPASSWORD=$(OE_DB_PASSWORD) openelis-db-external \
	  psql -U $(OE_DB_USER) -d $(OE_DB_NAME)
