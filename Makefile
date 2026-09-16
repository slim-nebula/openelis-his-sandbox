# =============================================================================
# OpenELIS <-> HIS sandbox
#
#   make up          bring everything up in the right order
#   make sync-catalogue  read the orderable test menu from OpenELIS
#   make smoke       platform smoke test   (brief phase 1)
#   make e2e         order flow test       (brief phase 2/3)
#   make results     result return path
#   make rejection   LIS rejection round trip
#   make negative    negative-path test    (brief phase 4)
#   make auth        authentication test
#   make progress    laboratory progress inside an order
#   make token       sign in (stands in for IAM), prints a user token
#   make certs       reissue the OpenELIS <-> bridge certificates (`up` does it)
#   make down        stop applications, keep data
#   make clean       destroy everything including volumes
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENVFILE := --env-file .env
DATA    := docker compose -p his-lab-data $(ENVFILE) -f compose/data.yml
APP     := docker compose -p his-lab-sandbox $(ENVFILE) \
             -f compose/platform.yml -f compose/apps.yml -f compose/openelis.yml

# .env holds the values and is not committed; .env.example holds the shape and
# is. Without it `include` fails with a line number instead of an instruction,
# so say the useful thing - while still letting `secrets` and `help` run, since
# those are what you reach for when it is missing.
ifeq (,$(wildcard .env))
  ifeq (,$(filter secrets help,$(MAKECMDGOALS)))
    $(error No .env found. Run `make secrets` to generate one from .env.example)
  endif
else
  include .env
  export
endif

.PHONY: help secrets config data-up app-up up down clean logs ps \
        smoke e2e results rejection corrections catalogue-test negative auth capture token \
        requester panel monitoring patient-refresh \
        certs trust-bridge progress alerts dead-letters reconcile \
        sync-catalogue catalogue export-status prune migrate psql-his psql-oe topics urls \
        billing-check billing-map certs-rotate unit

help:
	@grep -hE '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	 awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

secrets: ## Create .env from .env.example, generating the passwords and tokens
	@bash scripts/init-secrets.sh

config: ## Render templated configuration from .env and issue the integration certificates
	@bash scripts/render-config.sh
	@# Before anything starts, because two containers read these files as they
	@# boot: the bridge serves its FHIR port with bridge.crt, and OpenELIS's
	@# truststore has our CA imported into it. Leaving this as a manual step is
	@# what made a fresh clone come up with a crashlooping bridge and a
	@# laboratory that never received an order.
	@bash scripts/init-mtls.sh

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

# There is deliberately no `provision` target any more. Reshaping OpenELIS's
# seeded catalogue to suit the HIS was the wrong side to change: the LIS is the
# accredited component and its catalogue belongs to the laboratory. Ambiguous
# tests are now handled by not offering them (see `make sync-catalogue`), and
# openelis/provision/undo-catalogue-curation.sql reverses the edits for anyone
# who applied the old script.

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
	@echo "  HIS API (via Kong)     http://localhost:$(EDGE_HTTP_PORT)/api/health"
	@echo "  Kong admin             http://localhost:$(KONG_ADMIN_PORT)"
	@echo "  OpenELIS UI            https://localhost:$(OE_UI_HTTPS_PORT)   (admin / $(OE_DEFAULT_PASSWORD))"
	@echo "  Bridge FHIR endpoint   docker exec bridge curl -s http://localhost:8080/fhir/metadata"
	@echo "  Prometheus             http://localhost:$(PROMETHEUS_PORT)   (make alerts)"
	@echo "  HIS database           psql -h localhost -p $(HIS_DB_PUBLISHED_PORT) -U $(HIS_DB_USER) -d $(HIS_DB_NAME)"
	@echo "  OpenELIS database      psql -h localhost -p $(OE_DB_PUBLISHED_PORT) -U $(OE_DB_USER) -d $(OE_DB_NAME)"

unit: ## Unit tests for the bridge's pure functions (no stack required)
	@cd services/bridge && npm test

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

collection: ## Specimen collection - the outpatient and inpatient workflows
	@bash scripts/test-collection.sh

requester: ## The ordering clinician, from the doctor's screen to the laboratory's
	@bash scripts/test-requester.sh

panel: ## A report with several analytes - the whole panel, not just its first
	@bash scripts/test-panel.sh

monitoring: ## The collector, the gauges, and whether the alerts can actually fire
	@bash scripts/test-monitoring.sh

patient-refresh: ## Does a corrected patient name reach the laboratory? (upstream defect 07)
	@bash scripts/test-patient-refresh.sh

catalogue-test: ## Catalogue discovery - filters, guards and the HIS mirror
	@bash scripts/test-catalogue-sync.sh

sync-catalogue: ## Refresh the test menu from OpenELIS (FORCE=true to override the shrink guard)
	@echo "==> Reading the test menu from OpenELIS"
	@docker exec bridge curl -sS -X POST \
	  -H "Authorization: Bearer $(BRIDGE_ADMIN_TOKEN)" \
	  "http://localhost:8080/catalogue/sync$(if $(FORCE),?force=$(FORCE),)" \
	  --max-time 600 -o /tmp/sync.json -w '' || true
	@docker exec bridge cat /tmp/sync.json | python3 -c "import sys,json; d=json.load(sys.stdin); \
	  print('    applied:', d['applied'], '|', d['testsBefore'], '->', d['testsAfter']); \
	  [print('    +', a) for a in d['diff']['added']]; \
	  [print('    -', r) for r in d['diff']['removed']]; \
	  [print('    ~', c) for c in d['diff']['changed']]; \
	  print('    REFUSED:', d['reason']) if not d['applied'] else None"
	@echo "==> Mirroring it into the HIS"
	@docker exec his-api curl -sS -X POST \
	  -H "Authorization: Bearer $(HIS_ADMIN_TOKEN)" \
	  http://localhost:8080/admin/catalogue/refresh \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); \
	  print('    offered', d['offered'], '| updated', d['upserted'], '| withdrawn', d['deactivated']) \
	  if d['applied'] else print('    REFUSED:', d['reason'])"
	@# A synced test is orderable immediately and billable only once a human maps
	@# it. Reporting that here, rather than leaving it to be remembered, is the
	@# whole point of the check. Non-fatal: the sync itself succeeded, and an
	@# unmapped test is a normal state between enabling a test and pricing it.
	@echo "==> Billing coverage"
	@bash scripts/check-billing-map.sh 2>/dev/null | grep -E 'carry a billing|cannot be billed|^    ' || true

alerts: ## What is firing right now, and what is merely pending
	@docker exec his-prometheus wget -qO- http://localhost:9090/api/v1/alerts \
	  | python3 -c "import sys,json; \
	  a=json.load(sys.stdin)['data']['alerts']; \
	  print('    nothing firing') if not a else \
	  [print(f\"    [{x['labels']['severity'].upper():<8}] {x['labels']['alertname']:<26} {x['state']:<8} {x['annotations']['summary']}\") for x in \
	   sorted(a, key=lambda x: (x['state'] != 'firing', x['labels']['alertname']))]"

dead-letters: ## Failures that need a human, newest first
	@docker exec bridge curl -sS -H "Authorization: Bearer $(BRIDGE_ADMIN_TOKEN)" \
	  http://localhost:8080/ops/dead-letters \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); \
	  print('    none') if not d else \
	  [print(f\"    {r['createdAt'][:19]}  {r['source']:<22} {r['reason'][:110]}\") for r in d]"

reconcile: ## The order ledger - taken on vs resulted, day by day (DAYS=7)
	@docker exec bridge curl -sS -H "Authorization: Bearer $(BRIDGE_ADMIN_TOKEN)" \
	  "http://localhost:8080/ops/reconciliation?days=$(if $(DAYS),$(DAYS),7)" \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); t=d['totals']; \
	  print(f\"    {d['days']} days: {t['accepted']} taken on | {t['acceptedByLis']} accepted | \" \
	        f\"{t['rejectedByLis']} rejected | {t['resulted']} resulted | \" \
	        f\"{t['outstanding']} outstanding ({t['outstandingOverADay']} over a day) | \" \
	        f\"{t['deadLetters']} dead\"); \
	  print(f\"    {'day':<12}{'on':>5}{'acc':>6}{'rej':>6}{'res':>6}{'out':>6}{'>1d':>6}{'dead':>6}\"); \
	  [print(f\"    {r['day']:<12}{r['accepted']:>5}{r['acceptedByLis']:>6}{r['rejectedByLis']:>6}\" \
	         f\"{r['resulted']:>6}{r['outstanding']:>6}{r['outstandingOverADay']:>6}{r['deadLetters']:>6}\") \
	   for r in d['byDay']]"

export-status: ## Is OpenELIS still pushing results to us? (checks now)
	@docker exec bridge curl -sS -X POST \
	  -H "Authorization: Bearer $(BRIDGE_ADMIN_TOKEN)" \
	  http://localhost:8080/ops/export-status/check \
	  --max-time 300 | python3 -c "import sys,json; d=json.load(sys.stdin); \
	  print('   ', d['verdict'], '—', d['detail'])"

prune: ## Run the retention sweep now and report what it removed
	@docker exec bridge curl -sS -X POST \
	  -H "Authorization: Bearer $(BRIDGE_ADMIN_TOKEN)" \
	  http://localhost:8080/ops/retention/sweep --max-time 120 \
	  | python3 -c "import sys,json; \
	  [print(f\"    {r['table']:<22} kept {r['retained']:>7}  removed {r['deleted']:>6}  \" \
	         f\"(window {r['days']}d)\") for r in json.load(sys.stdin)]"

catalogue: ## Show the currently cached test menu
	@docker exec bridge curl -sS http://localhost:8080/catalogue | python3 -c "import sys,json; d=json.load(sys.stdin); \
	  print('    synced', d['syncedAt'], '—', d['count'], 'orderable tests'); \
	  [print(f\"      {t['loinc']:<12} {t['name']}  [{t['specimenName']}]\") for t in d['tests']]"

capture: ## Capture what OpenELIS really sends on release (needs a lab user)
	@bash scripts/capture-lis-result.sh $(ORDER)

negative: ## Phase 4 - negative paths
	@bash scripts/test-negative.sh

auth: ## User tokens, revocation, degraded mode, the audit trail and the internal key
	@bash scripts/test-auth.sh

progress: ## Phase 4b - where an order has got to inside the laboratory
	@bash scripts/test-progress.sh $(ORDER)

restart: ## Can a container restart lose an order? (~25 min; SKIP_OPENELIS=1 to skip Tomcat)
	@bash scripts/test-restart.sh $(TEST_CODE)

certs: ## Issue the certificates for the OpenELIS <-> bridge hop (FORCE=true to regenerate)
	@bash scripts/init-mtls.sh $(if $(FORCE),--force,)

billing-check: ## Does the billing map still cover the laboratory's menu?
	@bash scripts/check-billing-map.sh

billing-map: ## Show what each test is charged and claimed as
	@docker exec his-db-external psql -U $(HIS_DB_USER) -d $(HIS_DB_NAME) -c \
	  "SELECT m.loinc_code, m.specimen_type, c.test_name, m.charge_item_ref, \
	          coalesce(m.claim_code,'-') AS claim, m.is_active \
	     FROM his.lab_billing_map m \
	     LEFT JOIN his.test_catalogue c \
	       ON c.loinc_code = m.loinc_code AND c.specimen_type = m.specimen_type \
	    ORDER BY c.test_name, m.specimen_type;"

certs-rotate: ## Replace OpenELIS's keystore from the pinned certgen image (destroys the cert volumes)
	@echo "==> Rotating OpenELIS's TLS material."
	@echo "    certgen does not generate — it copies prebuilt keystores out of its"
	@echo "    image, so the only way to change the certificate is to change the"
	@echo "    pinned digest and clear the volumes it populates."
	@echo "    No patient data lives in these: keystore, truststore, nginx cert/key."
	@$(APP) down
	@docker volume rm his-lab-sandbox_oe-certs his-lab-sandbox_oe-key-trust-store \
	  his-lab-sandbox_oe-keys 2>/dev/null || true
	@# Force a fresh export: init-mtls keeps an existing peer certificate, which
	@# after a rotation is the one we are trying to replace.
	@rm -f certs/openelis-client.crt
	@$(MAKE) --no-print-directory app-up
	@echo "==> New peer certificate:"
	@openssl x509 -in certs/openelis-client.crt -noout -subject -dates 2>/dev/null \
	  || echo "    !! not exported — check: make logs S=oe-peer-cert"
	@echo "==> Confirm the handshake before trusting this:"
	@echo "    docker exec bridge curl -s http://127.0.0.1:8080/metrics | grep fhir_requests"

trust-bridge: ## Import our CA into OpenELIS's truststore, then restart it
	@$(APP) up oe-trust-bridge
	@echo "==> Restarting OpenELIS: the truststore is read once, at startup"
	@docker restart openelis-webapp >/dev/null

openelis-patched: ## Build OpenELIS from the upstream tag with our patches applied (VERSION=)
	@bash scripts/build-openelis.sh $(VERSION)

# USER and GROUPS are inherited from the SHELL by every make invocation — make
# imports the environment as variables — so a plain $(if $(USER),…) silently
# passed --user <your login name> here, minting usr_id: null and a token every
# service rejects with "Invalid token structure". It looked like it worked: the
# script printed a token and "Signed in as sandbox.user".
#
# $(origin …) is the fix rather than renaming the knob: it honours USER= typed
# on the command line and ignores the one the shell exported. GROUPS has the
# same collision (it is also a bash special variable), so it gets the same
# treatment.
token: ## Sign in as a sandbox user and print a token (USER=, NAME=, GROUPS=, TTL=)
	@bash scripts/mint-token.sh \
	  $(if $(filter command line,$(origin USER)),--user $(USER),) \
	  $(if $(NAME),--name $(NAME),) \
	  $(if $(filter command line,$(origin GROUPS)),--groups $(GROUPS),) \
	  $(if $(TTL),--ttl $(TTL),)

topics: ## List Kafka topics
	@docker exec his-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list

psql-his: ## Open psql on the HIS sandbox database
	@docker exec -it -e PGPASSWORD=$(HIS_DB_PASSWORD) his-db-external \
	  psql -U $(HIS_DB_USER) -d $(HIS_DB_NAME)

psql-oe: ## Open psql on the OpenELIS database
	@docker exec -it -e PGPASSWORD=$(OE_DB_PASSWORD) openelis-db-external \
	  psql -U $(OE_DB_USER) -d $(OE_DB_NAME)
