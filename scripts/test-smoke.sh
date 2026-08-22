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
check_contains "Reverse proxy answers /health" \
    "curl -sf http://localhost:${EDGE_HTTP_PORT}/health" '"status":"healthy"'
check_contains "Frontend is served at /" \
    "curl -sf http://localhost:${EDGE_HTTP_PORT}/" 'HIS Sandbox'
check_contains "Kong routes /api/health to his-api" \
    "curl -sf ${API}/health" '"service":"his-api-service"'
check_contains "Kong stamps a correlation id" \
    "curl -sfD - -o /dev/null ${API}/health" 'X-Correlation-ID'
check_contains "Test catalogue is reachable through the gateway" \
    "curl -sf ${API}/test-catalogue" 'loincCode'

section "Gateway configuration"
check_contains "Kong loaded the declarative routes" \
    "curl -sf http://localhost:${KONG_ADMIN_PORT}/routes" 'lab-orders-create'

# Addressing a Docker hostname let Kong cache an address that Docker later
# reassigned to another container — it served a request for the HIS API from
# the bridge. Routing by registered service name makes a moved container a
# registry update instead of a stale cache.
check_contains "Kong addresses the HIS by its Consul service name, not a container hostname" \
    "curl -sf http://localhost:${KONG_ADMIN_PORT}/services" 'his-api-service.service.consul'
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

# The producers already write with acks=all. min.insync.replicas is what gives
# that any meaning: without it, "all replicas acknowledged" can mean "the one
# replica that happened to be up". The two settings only work as a pair, and
# only the topic can be asked whether the second one was actually applied.
check "Topics carry the configured min.insync.replicas, so acks=all means something" \
    "[[ \$(docker exec his-kafka /opt/kafka/bin/kafka-configs.sh --bootstrap-server kafka:9092 \
            --entity-type topics --entity-name ${TOPIC_ORDER_CREATED} --describe \
          | grep -c 'min.insync.replicas=${KAFKA_MIN_INSYNC_REPLICAS}') -ge 1 ]]"

check "Topics are replicated as this deployment configured" \
    "[[ \$(docker exec his-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 \
            --describe --topic ${TOPIC_ORDER_CREATED} \
          | grep -o 'ReplicationFactor: [0-9]*' | head -1 | grep -o '[0-9]*') \
        == ${KAFKA_REPLICATION_FACTOR} ]]"

section "Bridge FHIR endpoint"
check_contains "Bridge is healthy" "in_sandbox http://localhost:8080/health" '"status":"healthy"'
check_contains "CapabilityStatement declares FHIR R4" \
    "in_sandbox http://localhost:8080/fhir/metadata" '4.0.1'
check_contains "Task search responds with a searchset bundle" \
    "in_sandbox 'http://localhost:8080/fhir/Task?status=requested&owner=${OE_REMOTE_SOURCE_IDENTIFIER}'" \
    'searchset'
check_contains "OpenELIS can reach the bridge's FHIR endpoint" \
    "docker exec openelis-webapp curl -sf ${BRIDGE_FHIR_BASE}/metadata" '4.0.1'

# A search that returns everything ever published gets slower as the deployment
# gets older, and is slowest exactly when the laboratory is busiest. The bundle
# reports the true match count alongside the capped page, so a truncated caller
# is never told it has seen everything.
check "A search page is capped, and says how many matches it capped from" \
    "docker exec bridge curl -sS 'http://localhost:8080/fhir/Task?_count=1' | python3 -c \"
import json,sys
b = json.load(sys.stdin)
entries, total = len(b.get('entry', [])), b['total']
assert entries <= 1, f'asked for 1, got {entries}'
assert total >= entries, f'total {total} is below the {entries} returned'
\""

check "A client asking for more than the server will serialise gets the server's answer" \
    "docker exec bridge curl -sS 'http://localhost:8080/fhir/Task?_count=100000' | python3 -c \"
import json,sys
b = json.load(sys.stdin)
assert len(b.get('entry', [])) <= ${BRIDGE_MAX_SEARCH_RESULTS}, 'cap not applied'
\""

section "Platform integration"

# The sandbox is a reference for the real HIS platform, so both services have to
# be visible to it the same way the Node services are: discoverable in Consul,
# scrapeable by Prometheus, and writing to the shared log topic.

for svc in bridge-service his-api-service; do
    check "$svc is registered in Consul" \
        "[[ \$(curl -sf http://localhost:${CONSUL_HTTP_PORT}/v1/catalog/service/$svc \
              | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') -ge 1 ]]"

    # Registration alone proves nothing. The first attempt registered the bridge
    # at its DATA-network address while Consul watches the sandbox network: it
    # appeared in the catalogue and every check failed. A service in the
    # catalogue that Consul cannot reach is worse than one that never
    # registered, because Kong will route to it.
    check "Consul can reach the address $svc advertised" \
        "[[ \$(curl -sf http://localhost:${CONSUL_HTTP_PORT}/v1/health/service/$svc \
              | python3 -c \"
import json,sys
bad = [c['Status'] for e in json.load(sys.stdin) for c in e['Checks']
       if c['Name'].endswith('-health') and c['Status'] != 'passing']
print('critical' if bad else 'passing')\") == passing ]]"

    check "$svc carries the estate's Consul tags" \
        "[[ \$(curl -sf http://localhost:${CONSUL_HTTP_PORT}/v1/catalog/service/$svc \
              | python3 -c \"
import json,sys
tags = set(json.load(sys.stdin)[0]['ServiceTags'])
print('ok' if {'hospital','microservice','load-balanced'} <= tags else f'missing from {tags}')\") == ok ]]"
done

check_contains "The bridge exposes Prometheus request histograms" \
    "docker exec bridge curl -sf http://localhost:8080/metrics" 'http_request_duration_seconds_bucket'
check_contains "The HIS service exposes them too" \
    "docker exec his-api curl -sf http://localhost:8080/metrics" 'http_request_duration_seconds_bucket'

# The log topic is SHARED with every other service in the estate. Two things
# have to hold: application logs arrive, and framework request chatter does not.
# Before the category filter, an idle bridge put ~2,800 lines on it in five
# minutes — none of them about a patient.
LOGS_SAMPLE=$(
    part=$(docker exec his-kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 \
             --topic "$TOPIC_LOGS" 2>/dev/null | sort -t: -k3 -n | tail -1)
    p=$(cut -d: -f2 <<< "$part"); end=$(cut -d: -f3 <<< "$part")
    start=$(( end > 40 ? end - 40 : 0 ))
    docker exec his-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 \
        --topic "$TOPIC_LOGS" --partition "$p" --offset "$start" --max-messages 40 2>/dev/null
)

check "Application logs reach the shared topic, in the estate's envelope" \
    "python3 -c \"
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip().startswith('{')]
assert rows, 'no messages on the log topic'
want={'service','level','message','timestamp'}
assert all(want <= set(r) for r in rows), f'envelope mismatch: {sorted(rows[0])}'
\" <<< \"\$LOGS_SAMPLE\""

# This one has to be CAUSAL, not historical. Sampling the tail of the topic
# tests whatever the service was doing last week; the question is what it does
# now. So: note the end offsets, generate requests, and look only at what those
# requests produced.
LOG_END_BEFORE=$(docker exec his-kafka /opt/kafka/bin/kafka-get-offsets.sh \
    --bootstrap-server kafka:9092 --topic "$TOPIC_LOGS" 2>/dev/null | awk -F: '{s+=$3} END {print s}')

for _ in $(seq 1 8); do
    docker exec bridge curl -sf -o /dev/null http://localhost:8080/health 2>/dev/null
    docker exec his-api curl -sf -o /dev/null http://localhost:8080/health 2>/dev/null
done
sleep 4

LOG_END_AFTER=$(docker exec his-kafka /opt/kafka/bin/kafka-get-offsets.sh \
    --bootstrap-server kafka:9092 --topic "$TOPIC_LOGS" 2>/dev/null | awk -F: '{s+=$3} END {print s}')

# 16 requests, each of which ASP.NET describes in four Information lines. Before
# the category filter that was ~64 messages on a topic shared with every service
# in the estate, none of them about a patient.
PRODUCED=$(( LOG_END_AFTER - LOG_END_BEFORE ))
if [[ $PRODUCED -le 8 ]]; then
    ok "16 health requests added $PRODUCED log message(s), not ~64 of framework chatter"
else
    bad "Framework request chatter is kept off the shared topic" \
        "16 requests produced $PRODUCED messages; the category filter is not applied"
fi

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
