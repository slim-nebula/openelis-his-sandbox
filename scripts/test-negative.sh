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
             \"facilityCode\":\"FAC-001\"}') == 400 ]]"

check "Unknown test code is rejected with 400" \
    "[[ \$(status_of -X POST ${API}/lab-orders -H 'Content-Type: application/json' \
        -d \"{\\\"patientId\\\":\\\"11111111-1111-1111-1111-111111111111\\\",\\\"testCode\\\":\\\"NOPE\\\",
             \\\"facilityCode\\\":\\\"FAC-001\\\"}\") == 400 ]]"

check "Neither rejection left an order behind" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_orders WHERE test_code = 'NOPE'\") == 0 ]]"

check "Unknown patient lookup returns 404" \
    "[[ \$(status_of ${API}/patients/00000000-0000-0000-0000-000000000000) == 404 ]]"

# ---------------------------------------------------------------------------
section "Duplicate event delivery is absorbed"

ORDER_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
         \"facilityCode\":\"FAC-001\"}")
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
section "One order is never handed to the laboratory twice at once"

# The failure this prevents is OpenELIS's, not ours. It was seen importing the
# same Task twice within two seconds, which 409s on a client-assigned FHIR id,
# aborts the import, leaves the Task unacknowledged so it is re-polled for ever
# — and on one pass produced a DUPLICATE PATIENT RECORD. Defect 0 in
# docs/catalogue-discovery-plan.md.
#
# We cannot make their import idempotent. We can decline to hand them the same
# order twice at the same moment, which is what removes the collision.

LEASE_TASK=$(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking
                          WHERE order_number = '$DUP_ORDER_NUMBER'")
POLL="http://127.0.0.1:8080/fhir/Task?status=requested&owner=${OE_REMOTE_SOURCE_IDENTIFIER}"

poll_has_task() {  # 1 if the poll offered our Task, 0 if it withheld it
    docker exec bridge curl -s "$POLL" \
      | python3 -c "import sys,json;print(sum(1 for e in json.load(sys.stdin).get('entry',[]) \
                    if e['resource']['id']=='$LEASE_TASK'))"
}

# Wait for the Task to be LEASED — by whoever leases it first — rather than
# waiting to win the poll ourselves.
#
# The first version of this called poll_has_task() in a loop until it saw the
# Task, which was wrong in a way worth recording: that helper issues the real
# delivery poll, so it competes with OpenELIS for the lease. When OpenELIS got
# there first it held the Task for the full lease and the loop timed out, and
# the test reported a broken lease when the lease had worked perfectly.
#
# The property under test is not "we can see it" — it is "once delivered, it is
# withheld". Those come apart the moment anything else polls, which is always.
# Wait for the Task to have been DELIVERED, not for a lease to be live.
#
# A live lease is a window, and OpenELIS closes it: the moment it imports the
# order it writes a verdict back, and the bridge ends the lease. On a fast import
# that window can be shorter than this loop's interval, so polling for
# `leased_until > now()` was testing whether we outran the laboratory. It timed
# out here against a Task that had been delivered, imported and ACCEPTED — the
# lease had worked perfectly and the assertion still failed.
#
# `deliveries` is the durable fact: it is incremented on every hand-over and, as
# of the release-instead-of-delete change, survives the verdict. That is the
# property worth asserting, and it is the one an operator would actually query.
LEASED=false
for _ in $(seq 1 60); do
    [[ -n "$(bridge_sql "SELECT 1 FROM bridge.delivery_leases
                          WHERE resource_id = '$LEASE_TASK' AND deliveries >= 1")" ]] \
        && { LEASED=true; break; }
    # Nudge it ourselves if OpenELIS has not polled yet. Harmless: whoever wins,
    # the Task ends up delivered, which is the precondition being established.
    poll_has_task >/dev/null
    sleep 2
done

if [[ "$LEASED" == true ]]; then
    ok "Handing an order to the laboratory takes a delivery lease on it"
else
    bad "Handing an order to the laboratory takes a delivery lease on it" \
        "no delivery recorded for $LEASE_TASK after 120s"
fi

task_status_now() {
    docker exec bridge curl -s "http://127.0.0.1:8080/fhir/Task/$LEASE_TASK" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null
}

# Captured while the lease is live, because OpenELIS is a live participant here:
# the moment it imports the order it writes a verdict back, which changes the
# Task's status AND releases the lease. Asserting later against a literal
# 'requested', or against a lease row that has since been deleted, tests whether
# we outran the laboratory — which is not the property and is not stable.
DELIVERIES=$(bridge_sql "SELECT deliveries FROM bridge.delivery_leases
                          WHERE resource_id = '$LEASE_TASK'")
STATUS_BEFORE=$(task_status_now)

check "…and a leased order is withheld from the polls that follow" \
    "[[ \$(poll_has_task) == 0 && \$(poll_has_task) == 0 && \$(poll_has_task) == 0 ]]"
info "the second concurrent import is what 409s and duplicates the patient"

# The distinction the whole design turns on. Withholding is a property of the
# SEARCH, not of the resource: the Task is not cancelled, reserved or altered by
# being handed over. A lease that mutated the Task would be lying to the
# laboratory about the order's state.
STATUS_AFTER=$(task_status_now)
if [[ -n "$STATUS_BEFORE" && "$STATUS_BEFORE" == "$STATUS_AFTER" ]]; then
    ok "Delivering the order did not change the Task (still '$STATUS_AFTER')"
else
    bad "Delivering the order did not change the Task" \
        "'$STATUS_BEFORE' became '$STATUS_AFTER'"
fi

check "…and a direct read is never withheld" \
    "[[ \$(docker exec bridge curl -s -o /dev/null -w '%{http_code}' \
          http://127.0.0.1:8080/fhir/Task/$LEASE_TASK) == 200 ]]"

check "…nor is a search by _id, which is a read and not a delivery" \
    "[[ \$(docker exec bridge curl -s 'http://127.0.0.1:8080/fhir/Task?_id=$LEASE_TASK' \
          | python3 -c \"import sys,json;print(len(json.load(sys.stdin).get('entry',[])))\") == 1 ]]"

# The attempt counter OpenELIS does not keep. Above one means the laboratory was
# given the order and never came back with a verdict.
check "The delivery was counted, so a failing import can be seen" \
    "[[ \${DELIVERIES:-0} -ge 1 ]]"

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

# Retried rather than read once.
#
# kafka-console-consumer with a fixed timeout is a poor oracle here: it reads
# from the beginning of a multi-partition topic and gives up on a wall clock, so
# a consumer-group rebalance — which this suite guarantees, having restarted the
# broker a few sections earlier — makes it return empty from a topic that holds
# the message. Observed exactly that: the assertion failed while the DLQ
# contained the record, correct payload and reason.
#
# The property is "it was dead-lettered", which is durable. Reading once is
# testing whether one consumer session happened to be quick enough.
DLQ_FOUND=""
for _ in $(seq 1 6); do
    if docker exec his-kafka /opt/kafka/bin/kafka-console-consumer.sh \
         --bootstrap-server kafka:9092 --topic "${TOPIC_RESULT_RELEASED}.dlq" \
         --from-beginning --timeout-ms 10000 2>/dev/null | grep -q 'this-is-not-json'; then
        DLQ_FOUND=yes; break
    fi
    sleep 3
done

if [[ -n "$DLQ_FOUND" ]]; then
    ok "The poison message was routed to the dead-letter topic"
else
    bad "The poison message was routed to the dead-letter topic" \
        "nothing matching in ${TOPIC_RESULT_RELEASED}.dlq after 6 reads"
fi

# ---------------------------------------------------------------------------
section "OpenELIS unavailable"

info "stopping openelis-webapp…"
docker stop openelis-webapp >/dev/null 2>&1

OFFLINE_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
         \"facilityCode\":\"FAC-001\"}")
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
         \"facilityCode\":\"FAC-001\"}")
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
             \"facilityCode\":\"FAC-001\"}')
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

# Retried rather than asserted once. The claim being tested is "it comes back
# WITHOUT anyone touching Kong", which is a claim about eventual recovery, not
# about latency — and recovery here legitimately takes longer than a restart,
# because Kong caches the upstream address for its DNS TTL and a restarted
# container can come back on a different one. `make up` restarts Kong for this
# exact reason. A single check the instant wait-for.sh gives up measures the
# TTL, not the behaviour.
BACK_CODE=""
for _ in $(seq 1 40); do
    BACK_CODE=$(status_of "${API}/health")
    [[ "$BACK_CODE" == 200 ]] && break
    sleep 3
done

if [[ "$BACK_CODE" == 200 ]]; then
    ok "And it returns to rotation without anyone touching Kong"
else
    bad "And it returns to rotation without anyone touching Kong" \
        "still http $BACK_CODE after 120s — Kong is not picking the instance back up"
fi

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

# The FHIR endpoint cannot use a bearer token: OpenELIS 3.2.1.11 has no way to
# send one. It uses a client CERTIFICATE instead, which OpenELIS has always been
# able to present — its shared HTTP client is built with loadKeyMaterial, and
# nothing had ever asked it for one.
check "A container that is not OpenELIS cannot reach the FHIR endpoint" \
    "[[ \$(http_status his-api GET http://bridge:8080/fhir/metadata) == 403 ]]"

check "A container that is not OpenELIS cannot push a result either" \
    "[[ \$(http_status his-api POST http://bridge:8080/fhir \
           -H 'Content-Type: application/fhir+json' \
           -d '{\"resourceType\":\"Bundle\",\"type\":\"transaction\"}') == 403 ]]"

if [[ "${BRIDGE_MTLS_ENABLED:-false}" == "true" ]]; then
    # The plaintext port stops being a way in. Without this the certificate is
    # decorative: anything unwilling to present one just uses the other port.
    check "Even OpenELIS is refused on the plaintext port" \
        "[[ \$(http_status openelis-webapp GET http://bridge:8080/fhir/metadata) == 403 ]]"

    check_contains "…and is told why, in FHIR" \
        "docker exec openelis-webapp curl -s --max-time 10 http://bridge:8080/fhir/metadata" \
        'requires a mutually authenticated TLS connection'

    # 000 is curl reporting that no HTTP response happened at all. That is the
    # point: the refusal is in the TLS handshake, before any request is sent.
    check "A caller with no client certificate cannot complete the handshake" \
        "[[ \$(http_status openelis-webapp GET https://bridge.openelis.org:8443/fhir/metadata -k) == 000 ]]"

    # Signed by the CA the bridge's own certificate comes from, and still
    # refused — because the peer is PINNED, not merely required to be
    # well-signed. Anyone who can get a certificate from the CA is not thereby
    # OpenELIS.
    openssl req -newkey rsa:2048 -sha256 -nodes -keyout "$ROOT/certs/rogue.key" \
        -out "$ROOT/certs/rogue.csr" -subj "/CN=impostor" 2>/dev/null
    openssl x509 -req -in "$ROOT/certs/rogue.csr" -CA "$ROOT/certs/ca.crt" \
        -CAkey "$ROOT/certs/ca.key" -CAcreateserial -out "$ROOT/certs/rogue.crt" \
        -days 1 -sha256 2>/dev/null

    check "A certificate signed by our own CA is still refused" \
        "[[ \$(http_status bridge GET https://bridge.openelis.org:8443/fhir/metadata \
               -k --cert /certs/rogue.crt --key /certs/rogue.key) == 000 ]]"
    info "the peer is pinned to one certificate, not trusted by issuer"

    rm -f "$ROOT/certs/rogue."{key,csr,crt}

    # The one thing configuration cannot fake: OpenELIS's own traffic, counted
    # as it arrives. BRIDGE_MTLS_ENABLED can be true while nothing is using the
    # port — the setting says what is allowed, the counter says what happened.
    #
    # Asserted as an INCREASE, not as non-zero. A non-zero counter would pass on
    # traffic from before this suite ran, including from a deployment where it
    # has since broken.
    MTLS_BEFORE=$(fhir_transport_count mtls)
    info "waiting for OpenELIS's next poll (every ${OE_REMOTE_POLL_FREQUENCY}ms)…"
    MTLS_AFTER=$MTLS_BEFORE
    for _ in $(seq 1 40); do
        MTLS_AFTER=$(fhir_transport_count mtls)
        [[ ${MTLS_AFTER:-0} -gt ${MTLS_BEFORE:-0} ]] && break
        sleep 3
    done

    check "OpenELIS keeps arriving over mutual TLS, live" \
        "[[ ${MTLS_AFTER:-0} -gt ${MTLS_BEFORE:-0} ]]"
    info "mutually authenticated FHIR requests: $MTLS_BEFORE -> $MTLS_AFTER"

    # Plaintext attempts are counted too, refusals included — which is why this
    # is not asserted to be zero: the checks above deliberately made some. The
    # counter exists so that a REAL deployment can alert on it, where anything
    # arriving in plaintext is a caller still using the old address.
    info "plaintext attempts so far (all refused): $(fhir_transport_count plaintext)"
else
    check "OpenELIS itself still reaches the FHIR endpoint" \
        "[[ \$(http_status openelis-webapp GET http://bridge:8080/fhir/metadata) == 200 ]]"
    info "BRIDGE_MTLS_ENABLED is false: the hop is plaintext, guarded by origin only"
fi

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
