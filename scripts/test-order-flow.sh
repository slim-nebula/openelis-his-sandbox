#!/usr/bin/env bash
# =============================================================================
# Phase 2/3 — order flow and result return
#
# Drives a real order from the client-facing API all the way into OpenELIS,
# checking each hop against the system that owns it, then waits for a lab user
# to release the result in OpenELIS and verifies it comes back.
#
#   scripts/test-order-flow.sh [TEST_CODE]
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Default to whatever the laboratory currently accepts, not to a code chosen
# when this was written. HGB used to be the default and stopped being orderable
# the moment discovery noticed OpenELIS cannot bind it to a single specimen —
# so this suite failed on its second step with an empty response body, which
# looks nothing like "the test menu changed". See any_active_test_code in
# lib.sh; the same trap has now caught two suites.
TEST_CODE="${1:-$(any_active_test_code)}"

if [[ -z "$TEST_CODE" ]]; then
    echo "  No orderable test in the HIS menu. Run: make sync-catalogue" >&2
    exit 1
fi
ACCEPT_TIMEOUT=180     # seconds to wait for OpenELIS to poll and accept
RESULT_TIMEOUT="${RESULT_TIMEOUT:-600}"

# ---------------------------------------------------------------------------
section "1 · Create a patient (frontend -> proxy -> Kong -> his-api)"

PATIENT_JSON=$(curl -sf -X POST "${API}/patients" \
    -H 'Content-Type: application/json' \
    -d '{"firstName":"Ibrahim","lastName":"Diallo","sex":"M",
         "dateOfBirth":"1979-11-02","phone":"+22370000042","nationalId":"NID-E2E-001"}')

PATIENT_ID=$(echo "$PATIENT_JSON" | json_field "['patientId']")
MRN=$(echo "$PATIENT_JSON" | json_field "['externalPatientId']")

if [[ -n "$PATIENT_ID" ]]; then
    ok "Patient created: $MRN ($PATIENT_ID)"
else
    bad "Patient created" "$PATIENT_JSON"
    summary; exit 1
fi

check "Patient is persisted in the HIS sandbox database" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.patients WHERE patient_id = '$PATIENT_ID'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "2 · Place a lab order"

ORDER_JSON=$(curl -sf -X POST "${API}/lab-orders" \
    -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"$PATIENT_ID\",\"testCode\":\"$TEST_CODE\",
         \"orderingProvider\":\"Dr. Konate\",\"facilityCode\":\"FAC-001\",\"priority\":\"routine\"}")

ORDER_ID=$(echo "$ORDER_JSON" | json_field "['orderId']")
ORDER_NUMBER=$(echo "$ORDER_JSON" | json_field "['orderNumber']")

if [[ -n "$ORDER_NUMBER" ]]; then
    ok "Order created: $ORDER_NUMBER"
else
    bad "Order created" "$ORDER_JSON"
    summary; exit 1
fi

check "Order is persisted in the HIS sandbox database" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'\") == 1 ]]"
check "Order creation is audited" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_order_events e JOIN his.lab_orders o USING (order_id) WHERE o.order_number = '$ORDER_NUMBER' AND e.event_type = 'ORDER_CREATED'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "3 · lab.order.created reaches Kafka"

check_contains "Event published to $TOPIC_ORDER_CREATED" \
    "docker exec his-kafka /opt/kafka/bin/kafka-console-consumer.sh \
       --bootstrap-server kafka:9092 --topic $TOPIC_ORDER_CREATED \
       --from-beginning --timeout-ms 12000 2>/dev/null" \
    "$ORDER_NUMBER"

# ---------------------------------------------------------------------------
section "4 · Bridge consumes the event and publishes a FHIR order"

info "waiting for the bridge to map the order…"
for _ in $(seq 1 20); do
    TASK_ID=$(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
    [[ -n "$TASK_ID" ]] && break
    sleep 2
done

if [[ -n "${TASK_ID:-}" ]]; then
    ok "Bridge tracked the order as FHIR Task $TASK_ID"
else
    bad "Bridge tracked the order" "nothing in bridge.order_tracking for $ORDER_NUMBER"
    summary; exit 1
fi

# OpenELIS polls every OE_REMOTE_POLL_FREQUENCY ms and flips the Task to
# accepted as soon as it imports it, so a status=requested search can legitimately
# come back empty here. Either outcome proves the Task was published correctly;
# what would be a real failure is the Task being invisible AND still requested.
TASK_QUERY=$(in_sandbox "http://localhost:8080/fhir/Task?status=requested&owner=${OE_REMOTE_SOURCE_IDENTIFIER}")
TASK_NOW=$(bridge_sql "SELECT task_status FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")

if [[ "$TASK_QUERY" == *"$TASK_ID"* ]]; then
    ok "Task is discoverable by exactly the query OpenELIS issues"
elif [[ "$TASK_NOW" != "requested" ]]; then
    ok "Task was already imported by OpenELIS before this check ran (status: $TASK_NOW)"
else
    bad "Task is discoverable by exactly the query OpenELIS issues" \
        "still 'requested' but absent from the poll query: ${TASK_QUERY:0:300}"
fi

check_contains "ServiceRequest carries the LOINC coding OpenELIS matches on" \
    "in_sandbox http://localhost:8080/fhir/ServiceRequest/$ORDER_NUMBER" \
    'loinc.org'

check_contains "ServiceRequest carries the HIS order number as its identifier" \
    "in_sandbox http://localhost:8080/fhir/ServiceRequest/$ORDER_NUMBER" \
    "$ORDER_NUMBER"

# OpenELIS's Incoming Orders view reads ServiceRequest/{external_id}, where
# external_id is identifier[0].value. If the resource id and that identifier
# ever diverge, ordering still works but every order shows the lab a warning
# and no test name.
SR_ID=$(bridge_sql "SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
if [[ "$SR_ID" == "$ORDER_NUMBER" ]]; then
    ok "ServiceRequest.id equals its identifier, as OpenELIS's order view requires"
else
    bad "ServiceRequest.id equals its identifier" \
        "id is '$SR_ID' but external_id will be '$ORDER_NUMBER'"
fi

# ---------------------------------------------------------------------------
section "5 · OpenELIS polls the bridge and imports the order"

info "waiting up to ${ACCEPT_TIMEOUT}s for OpenELIS's poll (every $((OE_REMOTE_POLL_FREQUENCY/1000))s)…"
ACCEPTED=""
for _ in $(seq 1 $((ACCEPT_TIMEOUT/5))); do
    STATUS=$(bridge_sql "SELECT task_status FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
    if [[ "$STATUS" == "accepted" || "$STATUS" == "rejected" ]]; then
        ACCEPTED="$STATUS"
        break
    fi
    sleep 5
done

case "$ACCEPTED" in
    accepted) ok "OpenELIS accepted the order (Task -> accepted)" ;;
    rejected)
        bad "OpenELIS accepted the order" \
            "Task was REJECTED — the LOINC no longer resolves to exactly one OpenELIS test. Re-run 'make sync-catalogue'."
        ;;
    *)  bad "OpenELIS accepted the order" \
            "Task still '$STATUS' after ${ACCEPT_TIMEOUT}s. Check: docker logs openelis-webapp | grep -i task" ;;
esac

ORDER_STATUS=$(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'")
if [[ "$ORDER_STATUS" == "ACCEPTED_BY_LIS" ]]; then
    ok "HIS order status reflects the LIS verdict: $ORDER_STATUS"
else
    bad "HIS order status reflects the LIS verdict" "status is '$ORDER_STATUS'"
fi

EO_COUNT=$(oe_sql "SELECT count(*) FROM clinlims.electronic_order WHERE external_id = '$ORDER_NUMBER'")
if [[ "${EO_COUNT:-0}" -ge 1 ]]; then
    ok "Electronic order exists in the OpenELIS database"
else
    bad "Electronic order exists in the OpenELIS database" \
        "no clinlims.electronic_order row with external_id = $ORDER_NUMBER"
fi

# ---------------------------------------------------------------------------
section "6 · Release the result in OpenELIS"

cat <<EOF

  The lab-side steps are deliberately manual — the point of this phase is that
  a real lab user drives OpenELIS:

    1. Open  https://localhost:${OE_UI_HTTPS_PORT}   (admin / ${OE_DEFAULT_PASSWORD})
    2. Order -> Incoming Orders, find $ORDER_NUMBER and accession it
    3. Enter a result under Work Plan / Results Entry
    4. Validate and release it under Validation

  Waiting up to $((RESULT_TIMEOUT/60)) minutes for the released result to come
  back through the bridge. Ctrl-C to stop waiting.

EOF

RESULT_FOUND=""
for _ in $(seq 1 $((RESULT_TIMEOUT/10))); do
    COUNT=$(his_sql "SELECT count(*) FROM his.lab_results_summary r JOIN his.lab_orders o USING (order_id) WHERE o.order_number = '$ORDER_NUMBER'")
    if [[ "${COUNT:-0}" -ge 1 ]]; then RESULT_FOUND=yes; break; fi
    printf '.'
    sleep 10
done
echo

if [[ -n "$RESULT_FOUND" ]]; then
    ok "Released result stored in the HIS sandbox database"
    his_rows "SELECT '        ' || test_name || ' = ' || coalesce(result_value,'?') || ' ' ||
                     coalesce(result_unit,'') || '  [' || result_status || ']  ref ' || openelis_result_ref
              FROM his.lab_results_summary r JOIN his.lab_orders o USING (order_id)
              WHERE o.order_number = '$ORDER_NUMBER'"

    check "Result keeps a back-reference to the OpenELIS record" \
        "[[ -n \$(his_sql \"SELECT openelis_result_ref FROM his.lab_results_summary r JOIN his.lab_orders o USING (order_id) WHERE o.order_number = '$ORDER_NUMBER'\") ]]"
    check "Order status advanced to RESULT_AVAILABLE" \
        "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'\") == RESULT_AVAILABLE ]]"
    check "Frontend can read the result through the gateway" \
        "curl -sf ${API}/patients/${PATIENT_ID}/results | grep -q openelisResultRef"
else
    bad "Released result stored in the HIS sandbox database" \
        "nothing arrived within $((RESULT_TIMEOUT/60)) min. Check: docker logs bridge | grep -i correlat"
fi

echo
info "Order number: $ORDER_NUMBER    Patient: $MRN"
summary
