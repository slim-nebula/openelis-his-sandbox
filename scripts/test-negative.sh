#!/usr/bin/env bash
# =============================================================================
# Phase 4 — negative paths
#
# Every case here is one the brief calls out: bad references, bad mappings,
# duplicate delivery, replayed results, and dependencies going away.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

produce() {   # produce <topic> <json>
    # kafka-console-producer treats every LINE as a separate message, so the
    # payload has to be collapsed onto one line first.
    printf '%s\n' "$(printf '%s' "$2" | tr -d '\n' | tr -s ' ')" | docker exec -i his-kafka \
        /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka:9092 --topic "$1" >/dev/null 2>&1
}

status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# ---------------------------------------------------------------------------
section "Invalid references are rejected at the edge"

check "Unknown patient id is rejected with 400" \
    "[[ \$(status_of -X POST ${API}/lab-orders -H 'Content-Type: application/json' \
        -d '{\"patientId\":\"00000000-0000-0000-0000-000000000000\",\"testCode\":\"HGB\",
             \"orderingProvider\":\"Dr. Test\",\"facilityCode\":\"FAC-001\"}') == 400 ]]"

check "Unknown test code is rejected with 400" \
    "[[ \$(status_of -X POST ${API}/lab-orders -H 'Content-Type: application/json' \
        -d \"{\\\"patientId\\\":\\\"11111111-1111-1111-1111-111111111111\\\",\\\"testCode\\\":\\\"NOPE\\\",
             \\\"orderingProvider\\\":\\\"Dr. Test\\\",\\\"facilityCode\\\":\\\"FAC-001\\\"}\") == 400 ]]"

check "Neither rejection left an order behind" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_orders WHERE test_code = 'NOPE'\") == 0 ]]"

check "Unknown patient lookup returns 404" \
    "[[ \$(status_of ${API}/patients/00000000-0000-0000-0000-000000000000) == 404 ]]"

# ---------------------------------------------------------------------------
section "Duplicate event delivery is absorbed"

ORDER_JSON=$(curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d '{"patientId":"11111111-1111-1111-1111-111111111111","testCode":"GLUC",
         "orderingProvider":"Dr. Duplicate","facilityCode":"FAC-001"}')
DUP_ORDER_ID=$(echo "$ORDER_JSON" | json_field "['orderId']")
DUP_ORDER_NUMBER=$(echo "$ORDER_JSON" | json_field "['orderNumber']")
info "seeded order $DUP_ORDER_NUMBER"

for _ in $(seq 1 20); do
    [[ -n $(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '$DUP_ORDER_NUMBER'") ]] && break
    sleep 2
done
TASKS_BEFORE=$(bridge_sql "SELECT count(*) FROM bridge.fhir_resources WHERE resource_type = 'Task'")

# Replay the exact same event, event id included.
DUP_EVENT_ID="replay-$(date +%s)"
produce "$TOPIC_ORDER_CREATED" "{\"eventId\":\"$DUP_EVENT_ID\",\"eventType\":\"lab.order.created\",
    \"correlationId\":\"negative-test\",\"orderId\":\"$DUP_ORDER_ID\",
    \"orderNumber\":\"$DUP_ORDER_NUMBER\",\"patientId\":\"11111111-1111-1111-1111-111111111111\",
    \"testCode\":\"GLUC\"}"
produce "$TOPIC_ORDER_CREATED" "{\"eventId\":\"$DUP_EVENT_ID\",\"eventType\":\"lab.order.created\",
    \"correlationId\":\"negative-test\",\"orderId\":\"$DUP_ORDER_ID\",
    \"orderNumber\":\"$DUP_ORDER_NUMBER\",\"patientId\":\"11111111-1111-1111-1111-111111111111\",
    \"testCode\":\"GLUC\"}"
sleep 8

TASKS_AFTER=$(bridge_sql "SELECT count(*) FROM bridge.fhir_resources WHERE resource_type = 'Task'")
if [[ "$TASKS_BEFORE" == "$TASKS_AFTER" ]]; then
    ok "Replayed lab.order.created produced no extra FHIR Task ($TASKS_AFTER)"
else
    bad "Replayed lab.order.created produced no extra FHIR Task" \
        "Task count went from $TASKS_BEFORE to $TASKS_AFTER"
fi

check "Only one tracking row exists for the order" \
    "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.order_tracking WHERE order_number = '$DUP_ORDER_NUMBER'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "Replayed result message does not duplicate the projection"

RESULT_REF="DiagnosticReport/negative-test-$(date +%s)"
RESULT_MSG="{\"eventId\":\"res-1\",\"correlationId\":\"negative-test\",
    \"orderNumber\":\"$DUP_ORDER_NUMBER\",\"openelisResultRef\":\"$RESULT_REF\",
    \"testCode\":\"GLUC\",\"testName\":\"Glucose\",\"resultValue\":\"5.4\",\"resultUnit\":\"mmol/L\",
    \"interpretation\":\"Normal\",\"resultStatus\":\"final\",\"releasedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

produce "$TOPIC_RESULT_RELEASED" "$RESULT_MSG"
sleep 5
produce "$TOPIC_RESULT_RELEASED" "$RESULT_MSG"
produce "$TOPIC_RESULT_RELEASED" "$RESULT_MSG"
sleep 8

ROWS=$(his_sql "SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = '$RESULT_REF'")
if [[ "$ROWS" == "1" ]]; then
    ok "Three deliveries of the same released result produced exactly one row"
else
    bad "Three deliveries produced exactly one row" "found $ROWS rows"
fi

check "Result for an unknown order is ignored rather than stored" "
    produce '$TOPIC_RESULT_RELEASED' '{\"orderNumber\":\"LAB-DOES-NOT-EXIST\",
        \"openelisResultRef\":\"DiagnosticReport/orphan\",\"resultValue\":\"1\",\"resultStatus\":\"final\",
        \"releasedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}'
    sleep 6
    [[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/orphan'\") == 0 ]]"

# The brief allows the bridge to return results over the internal API instead of
# Kafka; that path has to be just as idempotent.
docker exec bridge curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$RESULT_MSG" -o /dev/null http://his-api:8080/internal/lab-results 2>/dev/null
check "Direct POST to the internal result API is also idempotent" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = '$RESULT_REF'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "A poison message does not stall the partition"

# Regression test: an unparseable payload used to be retried forever with the
# offset uncommitted, which blocked every well-formed message behind it.
produce "$TOPIC_RESULT_RELEASED" 'this-is-not-json{{{'
sleep 4

GOOD_REF="DiagnosticReport/after-poison-$(date +%s)"
produce "$TOPIC_RESULT_RELEASED" "{\"orderNumber\":\"$DUP_ORDER_NUMBER\",
    \"openelisResultRef\":\"$GOOD_REF\",\"testCode\":\"GLUC\",\"testName\":\"Glucose\",
    \"resultValue\":\"6.1\",\"resultUnit\":\"mmol/L\",\"resultStatus\":\"final\",
    \"releasedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

DELIVERED=""
for _ in $(seq 1 15); do
    [[ $(his_sql "SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = '$GOOD_REF'") == "1" ]] \
        && { DELIVERED=yes; break; }
    sleep 3
done

if [[ -n "$DELIVERED" ]]; then
    ok "A valid message queued behind a poison one is still processed"
else
    bad "A valid message queued behind a poison one is still processed" \
        "the poison message blocked the partition"
fi

check "The poison message was routed to the dead-letter topic" \
    "docker exec his-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 \
       --topic ${TOPIC_RESULT_RELEASED}.dlq --from-beginning --timeout-ms 10000 2>/dev/null \
     | grep -q 'this-is-not-json'"

# ---------------------------------------------------------------------------
section "OpenELIS unavailable"

info "stopping openelis-webapp…"
docker stop openelis-webapp >/dev/null 2>&1

OFFLINE_JSON=$(curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d '{"patientId":"11111111-1111-1111-1111-111111111111","testCode":"CREA",
         "orderingProvider":"Dr. Offline","facilityCode":"FAC-001"}')
OFFLINE_NUMBER=$(echo "$OFFLINE_JSON" | json_field "['orderNumber']")

if [[ -n "$OFFLINE_NUMBER" ]]; then
    ok "Orders can still be placed while the LIS is down ($OFFLINE_NUMBER)"
else
    bad "Orders can still be placed while the LIS is down" "$OFFLINE_JSON"
fi

sleep 8
check "The order is queued as a FHIR Task, waiting for the LIS to come back" \
    "[[ \$(bridge_sql \"SELECT task_status FROM bridge.order_tracking WHERE order_number = '$OFFLINE_NUMBER'\") == requested ]]"

info "restarting openelis-webapp (it will pick the order up on its next poll)…"
docker start openelis-webapp >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "Kafka unavailable"

info "stopping kafka…"
docker stop his-kafka >/dev/null 2>&1
sleep 3

KAFKA_DOWN_CODE=$(status_of -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d '{"patientId":"11111111-1111-1111-1111-111111111111","testCode":"ALT",
         "orderingProvider":"Dr. NoKafka","facilityCode":"FAC-001"}')

if [[ "$KAFKA_DOWN_CODE" == "502" ]]; then
    ok "Order creation reports failure when the event cannot be published (HTTP 502)"
else
    bad "Order creation reports failure when the event cannot be published" \
        "got HTTP $KAFKA_DOWN_CODE, expected 502 — an order that is never published would silently never reach the LIS"
fi

check "The undispatched order is marked FAILED rather than left looking healthy" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_orders WHERE ordering_provider = 'Dr. NoKafka' AND order_status = 'FAILED'\") -ge 1 ]]"

info "restarting kafka…"
docker start his-kafka >/dev/null 2>&1
bash "$ROOT/scripts/wait-for.sh" "kafka" \
    "docker exec his-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server kafka:9092" 120

check "Sandbox recovers: a new order flows again" "
    resp=\$(curl -sf -X POST ${API}/lab-orders -H 'Content-Type: application/json' \
        -d '{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"CHOL\",
             \"orderingProvider\":\"Dr. Recovered\",\"facilityCode\":\"FAC-001\"}')
    number=\$(echo \"\$resp\" | python3 -c \"import json,sys; print(json.load(sys.stdin)['orderNumber'])\")
    for _ in \$(seq 1 20); do
        [[ -n \$(bridge_sql \"SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '\$number'\") ]] && exit 0
        sleep 2
    done
    exit 1"

section "Dead letters"
DLQ=$(bridge_sql "SELECT count(*) FROM bridge.dead_letters")
info "bridge dead-letter rows: ${DLQ:-0}  (inspect with: docker exec bridge curl -s http://localhost:8080/ops/dead-letters)"

summary
