#!/usr/bin/env bash
# =============================================================================
# Phase 1 — platform smoke test
#
# Proves the plumbing is in place before any clinical data moves: routing,
# messaging, the bridge's FHIR endpoint, and OpenELIS's connection to its
# external database.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Containers"
for container in his-db-external openelis-db-external his-kafka his-kong his-edge-proxy \
                 his-redis his-api bridge his-frontend openelis-webapp openelis-fhir openelis-proxy; do
    check "$container is running" \
        "[[ \$(docker inspect -f '{{.State.Running}}' $container 2>/dev/null) == true ]]"
done

section "Edge routing"
check_contains "Reverse proxy answers /healthz" \
    "curl -sf http://localhost:${EDGE_HTTP_PORT}/healthz" '"status":"ok"'
check_contains "Frontend is served at /" \
    "curl -sf http://localhost:${EDGE_HTTP_PORT}/" 'HIS Sandbox'
check_contains "Kong routes /api/healthz to his-api" \
    "curl -sf ${API}/healthz" '"component":"his-api"'
check_contains "Kong stamps a correlation id" \
    "curl -sfD - -o /dev/null ${API}/healthz" 'X-Correlation-ID'
check_contains "Test catalogue is reachable through the gateway" \
    "curl -sf ${API}/test-catalogue" 'loincCode'

section "Gateway configuration"
check_contains "Kong loaded the declarative routes" \
    "curl -sf http://localhost:${KONG_ADMIN_PORT}/routes" 'lab-orders-create'
check "Internal bridge API is NOT exposed through Kong" \
    "[[ \$(curl -s -o /dev/null -w '%{http_code}' ${API}/internal/lab-orders/00000000-0000-0000-0000-000000000000) == 404 ]]"

section "Messaging"
for topic in "$TOPIC_ORDER_CREATED" "$TOPIC_ORDER_SENT" "$TOPIC_ORDER_FAILED" \
             "$TOPIC_RESULT_RELEASED" "$TOPIC_RESULT_FAILED"; do
    check_contains "Topic $topic exists" \
        "docker exec his-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list" \
        "$topic"
done
check_contains "Bridge consumer group is registered" \
    "docker exec his-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:9092 --list" \
    'bridge'
check_contains "HIS API consumer group is registered" \
    "docker exec his-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:9092 --list" \
    'his-api'

section "Bridge FHIR endpoint"
check_contains "Bridge is healthy" "in_sandbox http://localhost:8080/healthz" '"status":"ok"'
check_contains "CapabilityStatement declares FHIR R4" \
    "in_sandbox http://localhost:8080/fhir/metadata" '4.0.1'
check_contains "Task search responds with a searchset bundle" \
    "in_sandbox 'http://localhost:8080/fhir/Task?status=requested&owner=${OE_REMOTE_SOURCE_IDENTIFIER}'" \
    'searchset'
check_contains "OpenELIS can reach the bridge's FHIR endpoint" \
    "docker exec openelis-webapp curl -sf ${BRIDGE_FHIR_BASE}/metadata" '4.0.1'

section "Data tier"
check "HIS schema is present" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue\") -ge 6 ]]"
check "Bridge schema is present" \
    "[[ \$(bridge_sql 'SELECT count(*) FROM bridge.fhir_resources') -ge 0 ]]"
check "OpenELIS database holds the clinlims schema" \
    "[[ \$(oe_sql \"SELECT count(*) FROM clinlims.test\") -gt 0 ]]"
check_contains "OpenELIS webapp is connected to the EXTERNAL database" \
    "docker exec openelis-webapp sh -c 'ps aux | grep -o \"datasource.url=[^ ]*\" | head -1'" \
    "${OE_DB_HOST}"
check "No database container is attached to the sandbox network" \
    "[[ -z \$(docker network inspect oe-sandbox-net -f '{{range .Containers}}{{.Name}} {{end}}' | grep -o 'db-external') ]]"

section "Test identity mapping"
LOINC_COUNT=$(oe_sql "SELECT count(*) FROM clinlims.test WHERE loinc IS NOT NULL AND loinc <> ''")
if [[ "${LOINC_COUNT:-0}" -ge 6 ]]; then
    ok "OpenELIS tests carry LOINC codes ($LOINC_COUNT)"
else
    bad "OpenELIS tests carry LOINC codes" \
        "found ${LOINC_COUNT:-0}; the seeded catalogue should carry these already"
fi

unmapped=""
while read -r code; do
    [[ -z "$code" ]] && continue
    found=$(oe_sql "SELECT count(*) FROM clinlims.test WHERE loinc = '$code'")
    [[ "${found:-0}" -ge 1 ]] || unmapped+="$code "
done < <(his_rows "SELECT loinc_code FROM his.test_catalogue WHERE is_active")

if [[ -z "$unmapped" ]]; then
    ok "Every HIS catalogue LOINC resolves to an OpenELIS test"
else
    bad "Every HIS catalogue LOINC resolves to an OpenELIS test" \
        "no OpenELIS test for LOINC: $unmapped"
fi

summary
