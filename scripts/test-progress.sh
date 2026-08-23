#!/usr/bin/env bash
# =============================================================================
# Phase 4b — where the order has got to inside the laboratory
#
# Between "the LIS accepted it" and "here is your result" there used to be
# nothing. That gap is hours long in a real laboratory, and silence in it is
# indistinguishable from the order having been lost — which is why wards
# telephone laboratories.
#
# The laboratory-side steps are simulated here, exactly as `make results`
# simulates a release: OpenELIS delivers each resource by PUT to the
# subscriber, so the suite does the same. What is NOT simulated is anything the
# bridge does with them.
#
#   scripts/test-progress.sh [ORDER_NUMBER]
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_NUMBER="${1:-}"
if [[ -z "$ORDER_NUMBER" ]]; then
    ORDER_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
        -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$(any_active_test_code)\",
             \"orderingProvider\":\"Dr. Progress\",\"facilityCode\":\"FAC-001\"}")
    ORDER_NUMBER=$(echo "$ORDER_JSON" | json_field "['orderNumber']")
fi

if [[ -z "$ORDER_NUMBER" ]]; then
    bad "Could not create an order to track"
    summary; exit 1
fi

info "tracking $ORDER_NUMBER"

for _ in $(seq 1 30); do
    OUR_SR=$(bridge_sql "SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
    [[ -n "$OUR_SR" ]] && break
    sleep 2
done

if [[ -z "${OUR_SR:-}" ]]; then
    bad "The bridge never published a ServiceRequest for $ORDER_NUMBER"
    summary; exit 1
fi

PATIENT_FHIR=$(bridge_sql "SELECT fhir_patient_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
LAB_SR=$(uuidgen | tr 'A-Z' 'a-z')
PRELIM_DR=$(uuidgen | tr 'A-Z' 'a-z')
ACCESSION="DEV$(date +%y%m%d%H%M%S)"

push() {  # push <Type> <id> <json>
    docker exec -i bridge curl -fsS -X PUT \
        -H 'Content-Type: application/fhir+json' \
        --data-binary @- -o /dev/null \
        "http://127.0.0.1:8080/fhir/$1/$2" <<< "$3"
}

progress_of() { his_sql "SELECT coalesce(lab_progress,'') FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'"; }
accession_of() { his_sql "SELECT coalesce(lab_accession,'') FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'"; }

wait_for_progress() {  # wait_for_progress <expected>
    for _ in $(seq 1 30); do
        [[ "$(progress_of)" == "$1" ]] && return 0
        sleep 3
    done
    return 1
}

# ---------------------------------------------------------------------------
section "1 · Before the laboratory says anything"

check "Progress is empty, not guessed" \
    "[[ -z \"\$(progress_of)\" ]]"
info "null means 'we have not been told', which is not the same as 'nothing has happened'"

# ---------------------------------------------------------------------------
section "2 · The sample is accessioned"

# What OpenELIS pushes once a technician books the sample in: its OWN
# ServiceRequest, pointing back at ours, carrying the laboratory's accession
# number under OpenELIS's system.
push ServiceRequest "$LAB_SR" "{
  \"resourceType\":\"ServiceRequest\",\"id\":\"$LAB_SR\",
  \"status\":\"active\",\"intent\":\"order\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$OUR_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
  \"requisition\":{\"use\":\"usual\",\"value\":\"$ACCESSION\",
                   \"system\":\"http://openelis-global.org/samp_labNo\"}
}" && ok "OpenELIS's accessioned ServiceRequest accepted" || bad "accessioned ServiceRequest accepted"

if wait_for_progress IN_LABORATORY; then
    ok "The HIS now says the sample is in the laboratory"
else
    bad "The HIS now says the sample is in the laboratory" "still '$(progress_of)'"
fi

check "…and carries the laboratory's own accession number" \
    "[[ \"\$(accession_of)\" == '$ACCESSION' ]]"
info "the accession is what a ward is asked for on the telephone"

# The distinction the whole feature turns on: this is a refinement UNDER the
# status, not a replacement for it. Anything reading order_status keeps working.
check "The order status is untouched" \
    "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number='$ORDER_NUMBER'\") == 'ACCEPTED_BY_LIS' ]]"

check "The progress step is on the order's audit trail" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_order_events e JOIN his.lab_orders o USING(order_id)
          WHERE o.order_number='$ORDER_NUMBER' AND e.event_type='LAB_IN_LABORATORY'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "3 · A result exists, but is not validated"

push DiagnosticReport "$PRELIM_DR" "{
  \"resourceType\":\"DiagnosticReport\",\"id\":\"$PRELIM_DR\",
  \"status\":\"preliminary\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$LAB_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
  \"issued\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"conclusion\":\"14.2 g/dL\"
}" && ok "preliminary report accepted by the bridge" || bad "preliminary report accepted"

if wait_for_progress AWAITING_VALIDATION; then
    ok "The HIS says a result is awaiting validation"
else
    bad "The HIS says a result is awaiting validation" "still '$(progress_of)'"
fi

# The point of the whole design. A clinician may know that a result exists; a
# clinician acting on an unvalidated value is a patient safety incident, and an
# unvalidated number looks exactly like a validated one on a screen.
check "…and NO result value reached the HIS" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary r JOIN his.lab_orders o USING(order_id)
          WHERE o.order_number='$ORDER_NUMBER'\") == 0 ]]"

check "The order status is still untouched" \
    "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number='$ORDER_NUMBER'\") == 'ACCEPTED_BY_LIS' ]]"

# ---------------------------------------------------------------------------
section "4 · Progress never runs backwards"

# Kafka orders messages within a partition, and these are keyed by order number
# — so out-of-order delivery needs a partition change, a rebalance mid-flight,
# or a replay after an incident. All three happen. A progress display that goes
# backwards makes a ward ring the laboratory about a test that is finished, so
# this is asserted rather than assumed.
BEFORE=$(progress_of)
docker exec -i his-kafka /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server kafka:9092 --topic "${TOPIC_ORDER_PROGRESS}" >/dev/null 2>&1 <<EOF
{"eventId":"replay-test","eventType":"lab.order.progress","orderNumber":"$ORDER_NUMBER","progress":"IN_LABORATORY","accessionNumber":"$ACCESSION","occurredAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
sleep 8

check "An earlier state replayed after a later one is ignored" \
    "[[ \"\$(progress_of)\" == '$BEFORE' ]]"
info "still $BEFORE, not IN_LABORATORY"

check "…and it did not add a second audit row" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_order_events e JOIN his.lab_orders o USING(order_id)
          WHERE o.order_number='$ORDER_NUMBER' AND e.event_type='LAB_IN_LABORATORY'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "5 · The frontend can read it"

ORDER_VIEW=$(api_curl -sf "${API}/patients/11111111-1111-1111-1111-111111111111/lab-orders")

check_contains "The order resource exposes labProgress" "echo '$ORDER_VIEW'" 'labProgress'
check_contains "…and the accession number" "echo '$ORDER_VIEW'" "$ACCESSION"

summary
