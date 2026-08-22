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

# Signed in, because everything it points at is behind the user token.
# /health ignores the extra header.
status_of() { api_status "$@"; }

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

ORDER_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
         \"orderingProvider\":\"Dr. Duplicate\",\"facilityCode\":\"FAC-001\"}")
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

OFFLINE_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
         \"orderingProvider\":\"Dr. Offline\",\"facilityCode\":\"FAC-001\"}")
OFFLINE_NUMBER=$(echo "$OFFLINE_JSON" | json_field "['orderNumber']")

if [[ -n "$OFFLINE_NUMBER" ]]; then
    ok "Orders can still be placed while the LIS is down ($OFFLINE_NUMBER)"
else
    bad "Orders can still be placed while the LIS is down" "$OFFLINE_JSON"
fi

sleep 8
check "The order is queued as a FHIR Task, waiting for the LIS to come back" \
    "[[ \$(bridge_sql \"SELECT task_status FROM bridge.order_tracking WHERE order_number = '$OFFLINE_NUMBER'\") == requested ]]"

# The failure this catches is the quiet one. Orders queue up visibly, but a
# laboratory that has stopped RETURNING results looks exactly like a laboratory
# with nothing ready — the bridge receives nothing either way. Someone has to be
# told, and until this check existed nobody was.
OFFLINE_VERDICT=$(bridge_admin POST /ops/export-status/check | json_field "['verdict']")
if [[ "$OFFLINE_VERDICT" != "OK" ]]; then
    ok "The result push channel is reported as $OFFLINE_VERDICT, not silently healthy"
else
    bad "The result push channel is not reported healthy while the LIS is down" \
        "verdict was OK — an outage would go unnoticed"
fi

check "The verdict is recorded, so an outage leaves a trace" \
    "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.export_status_checks
                        WHERE verdict <> 'OK' AND checked_at > now() - interval '5 minutes'\") -ge 1 ]]"

info "restarting openelis-webapp (it will pick the order up on its next poll)…"
docker start openelis-webapp >/dev/null 2>&1

bash "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh" "OpenELIS webapp" \
    "curl -skf -o /dev/null https://localhost/api/OpenELIS-Global/LoginPage" 300 || true

RECOVERED=$(bridge_admin POST /ops/export-status/check | json_field "['verdict']")
check "And it reports healthy again once the LIS is back" "[[ '$RECOVERED' == OK ]]"

# ---------------------------------------------------------------------------
section "Kafka unavailable"

info "stopping kafka…"
docker stop his-kafka >/dev/null 2>&1
sleep 3

# With the transactional outbox, a broker outage is invisible to the caller:
# the order and its event commit together and the relay drains the event when
# the broker returns. Ordering must not depend on Kafka being up.
KAFKA_DOWN_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
         \"orderingProvider\":\"Dr. NoKafka\",\"facilityCode\":\"FAC-001\"}")
NOKAFKA_ORDER=$(echo "$KAFKA_DOWN_JSON" | json_field "['orderNumber']")

if [[ -n "$NOKAFKA_ORDER" ]]; then
    ok "Orders are still accepted while the broker is down ($NOKAFKA_ORDER)"
else
    bad "Orders are still accepted while the broker is down" "$KAFKA_DOWN_JSON"
fi

check "The event is durably queued in the outbox, not lost" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.outbox o JOIN his.lab_orders l ON l.order_id = o.aggregate_id
          WHERE l.order_number = '$NOKAFKA_ORDER' AND o.published_at IS NULL\") == 1 ]]"

check "The order is NOT marked FAILED — nothing has actually failed" \
    "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number='$NOKAFKA_ORDER'\") == CREATED ]]"

info "restarting kafka…"
docker start his-kafka >/dev/null 2>&1
bash "$ROOT/scripts/wait-for.sh" "kafka" \
    "docker exec his-kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server kafka:9092" 120

# The order placed during the outage must now dispatch itself, with nobody
# retrying by hand. This is the property the outbox exists to provide.
DRAINED=""
for _ in $(seq 1 30); do
    [[ $(his_sql "SELECT count(*) FROM his.outbox o JOIN his.lab_orders l ON l.order_id = o.aggregate_id
                  WHERE l.order_number = '$NOKAFKA_ORDER' AND o.published_at IS NOT NULL") == "1" ]] \
        && { DRAINED=yes; break; }
    sleep 3
done

if [[ -n "$DRAINED" ]]; then
    ok "The relay drained the queued event once the broker returned"
else
    bad "The relay drained the queued event once the broker returned" \
        "outbox row for $NOKAFKA_ORDER is still unpublished"
fi

check "And the order reached the bridge without manual intervention" "
    for _ in \$(seq 1 20); do
        [[ -n \$(bridge_sql \"SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number='$NOKAFKA_ORDER'\") ]] && exit 0
        sleep 3
    done
    exit 1"

check "Sandbox recovers: a new order flows again" "
    resp=\$(api_curl -sf -X POST ${API}/lab-orders -H 'Content-Type: application/json' \
        -d '{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
             \"orderingProvider\":\"Dr. Recovered\",\"facilityCode\":\"FAC-001\"}')
    number=\$(echo \"\$resp\" | python3 -c \"import json,sys; print(json.load(sys.stdin)['orderNumber'])\")
    for _ in \$(seq 1 20); do
        [[ -n \$(bridge_sql \"SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '\$number'\") ]] && exit 0
        sleep 2
    done
    exit 1"

section "Dead letters"
DLQ=$(bridge_sql "SELECT count(*) FROM bridge.dead_letters")
info "bridge dead-letter rows: ${DLQ:-0}  (inspect with: bridge_admin GET /ops/dead-letters)"

# ---------------------------------------------------------------------------
section "An unhealthy service leaves the rotation by itself"

# Kong used to address his-api by its Docker hostname, cached the address, and
# once served a request for the HIS API from the BRIDGE after Docker reassigned
# it. Routing by Consul service name fixes that, and buys something further:
# Consul only answers with instances whose health check passes, so a service
# that cannot reach its database stops receiving traffic instead of being
# routed to and failing every request.
info "stopping his-api…"
docker stop his-api >/dev/null 2>&1

DROPPED=""
for _ in $(seq 1 12); do
    [[ $(curl -s "http://localhost:${CONSUL_HTTP_PORT}/v1/health/service/his-api-service?passing" \
         | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null) == "0" ]] \
        && { DROPPED=yes; break; }
    sleep 5
done

if [[ -n "$DROPPED" ]]; then
    ok "Consul withdrew the failed instance from service discovery"
else
    bad "Consul withdrew the failed instance from service discovery" \
        "it is still being advertised as passing"
fi

# Withdrawal is eventual, not instantaneous: Consul notices within its 10s check
# interval, and Kong may serve a cached record for up to dns_stale_ttl after
# that. Asserting on the instant Consul drops it tests the propagation delay
# rather than the behaviour — which is what this did on its first run, catching
# Kong mid-cache with a 502.
#
# What must hold is that Kong stops returning SUCCESS. 503 (no address to route
# to) and 502 (routed to a container that is gone) are both refusals; 200 from a
# stopped service would be a lie.
GONE_CODE=""
for _ in $(seq 1 10); do
    GONE_CODE=$(status_of "${API}/health")
    [[ "$GONE_CODE" =~ ^5 ]] && break
    sleep 3
done

if [[ "$GONE_CODE" =~ ^5 ]]; then
    ok "Kong refuses rather than routing to an instance that is gone (http $GONE_CODE)"
else
    bad "Kong refuses rather than routing to an instance that is gone" \
        "got http $GONE_CODE — a stopped service is still being served"
fi

info "restarting his-api…"
docker start his-api >/dev/null 2>&1
bash "$(dirname "${BASH_SOURCE[0]}")/wait-for.sh" "his-api" \
    "curl -sf -o /dev/null ${API}/health" 180 || true

check "And it returns to rotation without anyone touching Kong" \
    "[[ \$(status_of ${API}/health) == 200 ]]"

# ---------------------------------------------------------------------------
section "Callers without the right to act are refused"

# These assert on the STATUS CODE rather than the body. A refusal that returns
# 200 with an error message in it passes any test that greps the body, and is
# indistinguishable from success to every client.

check "No token: the catalogue sync is refused" \
    "[[ \$(http_status bridge POST http://localhost:8080/catalogue/sync) == 401 ]]"

check "Wrong token: the catalogue sync is still refused" \
    "[[ \$(http_status bridge POST http://localhost:8080/catalogue/sync \
           -H 'Authorization: Bearer not-the-token') == 401 ]]"

check "Right token: the same call is allowed through to the handler" \
    "[[ \$(http_status bridge GET http://localhost:8080/ops/dead-letters \
           -H \"Authorization: Bearer \$BRIDGE_ADMIN_TOKEN\") == 200 ]]"

check "No token: the HIS catalogue refresh is refused" \
    "[[ \$(http_status his-api POST http://localhost:8080/admin/catalogue/refresh) == 401 ]]"

# The HIS's test menu USED to be asserted open here, on the grounds that
# locking the ordering screen out of its own menu is a worse failure than
# leaving the menu readable. That argument was about a screen with no
# credential to present; the screen now holds a user token for everything else
# it does, so the menu sits behind the same door as the orders placed from it.
check "The HIS test menu needs a user token" \
    "[[ \$(http_status his-api GET http://localhost:8080/test-catalogue) == 401 ]]"

check "…and is served to a signed-in user" \
    "[[ \$(http_status his-api GET http://localhost:8080/test-catalogue \
           -H \"Authorization: Bearer \$HIS_TOKEN\") == 200 ]]"

# The bridge's copy stays open: it is the laboratory's list of orderable tests,
# read service-to-service by the HIS, and holds no patient data at all.
check "The bridge's cached menu is still readable without a token" \
    "[[ \$(http_status bridge GET http://localhost:8080/catalogue) == 200 ]]"

# These must STAY open. A health check that can fail authentication reports an
# outage that is not happening, and takes the service out of Kong's rotation
# for a reason that has nothing to do with its health.
check "Health checks are still readable without a token" \
    "[[ \$(http_status bridge GET http://localhost:8080/health) == 200 ]]"

check "…and so are metrics, on both services" \
    "[[ \$(http_status his-api GET http://localhost:8080/metrics) == 200 ]]"

# The FHIR endpoint cannot use a token: OpenELIS 3.2.1.11 has no way to send
# one. It is restricted by origin instead — so what has to be proved is that
# the restriction distinguishes OpenELIS from everything else that shares a
# network with the bridge, and that it has not simply been left off.
check "A container that is not OpenELIS cannot reach the FHIR endpoint" \
    "[[ \$(http_status his-api GET http://bridge:8080/fhir/metadata) == 403 ]]"

check "A container that is not OpenELIS cannot push a result either" \
    "[[ \$(http_status his-api POST http://bridge:8080/fhir \
           -H 'Content-Type: application/fhir+json' \
           -d '{\"resourceType\":\"Bundle\",\"type\":\"transaction\"}') == 403 ]]"

check "OpenELIS itself still reaches the FHIR endpoint" \
    "[[ \$(http_status openelis-webapp GET http://bridge:8080/fhir/metadata) == 200 ]]"

# ---------------------------------------------------------------------------
section "Retention removes what is finished and keeps what is not"

# Ageing rows on both sides of the guard is the only way to test this. A sweep
# run against fresh data deletes nothing and passes whatever it is asserted
# against, including a sweep that is broken.
RET_BEFORE_DONE=$(bridge_sql "SELECT count(*) FROM bridge.received_resources WHERE processed = true")
RET_BEFORE_OPEN=$(bridge_sql "SELECT count(*) FROM bridge.received_resources WHERE processed = false")

if [[ ${RET_BEFORE_DONE:-0} -ge 1 && ${RET_BEFORE_OPEN:-0} -ge 1 ]]; then
    bridge_sql "UPDATE bridge.received_resources SET received_at = now() - interval '400 days'
                WHERE (resource_type, resource_id) IN (
                  SELECT resource_type, resource_id FROM bridge.received_resources
                  WHERE processed = true LIMIT 1)" >/dev/null
    bridge_sql "UPDATE bridge.received_resources SET received_at = now() - interval '400 days'
                WHERE (resource_type, resource_id) IN (
                  SELECT resource_type, resource_id FROM bridge.received_resources
                  WHERE processed = false LIMIT 1)" >/dev/null

    # Counted, not assumed. Each run of this suite ages one more row, so the
    # aged-and-uncorrelated set grows across runs — an assertion of "exactly 1"
    # passes once and then fails for ever, which says nothing about the sweep.
    AGED_OPEN_BEFORE=$(bridge_sql "SELECT count(*) FROM bridge.received_resources
                                   WHERE processed = false AND received_at < now() - interval '390 days'")

    bridge_admin POST /ops/retention/sweep >/dev/null

    check "The aged, already-correlated resource is removed" \
        "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.received_resources
                            WHERE processed = true AND received_at < now() - interval '390 days'\") -eq 0 ]]"

    # This is the assertion that matters. An unprocessed resource is a result
    # that has not reached the patient's record yet; its age is not evidence
    # that it never will, and a sweep that treats age as permission to delete
    # would lose it silently.
    check "The aged resource that has NOT been correlated is kept ($AGED_OPEN_BEFORE of them)" \
        "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.received_resources
                            WHERE processed = false AND received_at < now() - interval '390 days'\") \
            -eq ${AGED_OPEN_BEFORE:-0} && ${AGED_OPEN_BEFORE:-0} -ge 1 ]]"
else
    info "skipped: needs at least one processed and one unprocessed mirror row"
fi

# Not "does the sweep run" but "is it running with the windows this deployment
# configured". The failure mode is a variable added to .env and never wired
# through compose: the sweeper then silently uses its compiled-in default, and
# a laboratory that set 400 days for an audit hold gets 30.
check "The sweep uses the windows this deployment configured, not its defaults" \
    "[[ \$(bridge_admin POST /ops/retention/sweep | python3 -c \"
import json,sys
want = {'received_resources': $RETENTION_RECEIVED_DAYS,
        'processed_events': $RETENTION_EVENTS_DAYS,
        'export_status_checks': $RETENTION_EXPORT_CHECKS_DAYS,
        'dead_letters': $RETENTION_DEAD_LETTERS_DAYS}
got = {r['table']: r['days'] for r in json.load(sys.stdin)}
print('match' if got == want else f'MISMATCH want={want} got={got}')\") == match ]]"

summary
