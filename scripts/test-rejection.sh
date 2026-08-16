#!/usr/bin/env bash
# =============================================================================
# LIS rejection round trip
#
# The branch this covers is catalogue drift: a test exists in the HIS catalogue
# but nobody mapped its LOINC code in OpenELIS. The HIS accepts the order
# happily — the code IS in its catalogue — so the failure only becomes visible
# once OpenELIS has looked at it and refused:
#
#   order accepted by HIS  ->  bridge publishes Task  ->  OpenELIS finds no test
#   ->  PUT Task status=rejected  ->  lab.order.failed  ->  REJECTED_BY_LIS
#
# This is distinct from the "invalid test code" case in test-negative.sh, which
# is rejected by the HIS at the edge with a 400 and never reaches Kafka.
#
# The fixture is a catalogue row that stays in place but inactive between runs,
# so the seeded catalogue keeps satisfying the smoke test's "every active LOINC
# resolves to an OpenELIS test" assertion.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNMAPPED_CODE="DRIFT"
UNMAPPED_LOINC="99999-9"
REJECT_TIMEOUT=240

cleanup() {
    his_sql "UPDATE his.test_catalogue SET is_active = false WHERE test_code = '$UNMAPPED_CODE'" >/dev/null
    info "fixture deactivated (catalogue row kept: orders reference it)"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "1 · Set up catalogue drift"

his_sql "INSERT INTO his.test_catalogue
             (test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit, is_active)
         VALUES ('$UNMAPPED_CODE', 'Unmapped Drift Test', '$UNMAPPED_LOINC', 'Serum', '119364003', 'U/L', true)
         ON CONFLICT (test_code) DO UPDATE SET is_active = true" >/dev/null

check "HIS catalogue offers $UNMAPPED_CODE" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE test_code='$UNMAPPED_CODE' AND is_active\") == 1 ]]"

# The whole point of the test: this LOINC must resolve to nothing in the LIS.
check "No OpenELIS test carries LOINC $UNMAPPED_LOINC" \
    "[[ \$(oe_sql \"SELECT count(*) FROM clinlims.test WHERE loinc = '$UNMAPPED_LOINC'\") == 0 ]]"

# ---------------------------------------------------------------------------
section "2 · The HIS accepts the order — it cannot know the LIS will refuse"

ORDER_JSON=$(curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$UNMAPPED_CODE\",
         \"orderingProvider\":\"Dr. Drift\",\"facilityCode\":\"FAC-001\"}")
ORDER_NUMBER=$(echo "$ORDER_JSON" | json_field "['orderNumber']")

if [[ -n "$ORDER_NUMBER" ]]; then
    ok "Order accepted by the HIS: $ORDER_NUMBER"
else
    bad "Order accepted by the HIS" "$ORDER_JSON"
    summary; exit 1
fi

# ---------------------------------------------------------------------------
section "3 · Bridge publishes it for OpenELIS"

for _ in $(seq 1 20); do
    TASK_ID=$(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
    [[ -n "$TASK_ID" ]] && break
    sleep 2
done

if [[ -n "${TASK_ID:-}" ]]; then
    ok "Bridge published FHIR Task $TASK_ID"
else
    bad "Bridge published a FHIR Task" "no bridge.order_tracking row for $ORDER_NUMBER"
    summary; exit 1
fi

check_contains "ServiceRequest carries the unmapped LOINC" \
    "in_sandbox http://localhost:8080/fhir/ServiceRequest/\$(bridge_sql \"SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number='$ORDER_NUMBER'\")" \
    "$UNMAPPED_LOINC"

# ---------------------------------------------------------------------------
section "4 · OpenELIS refuses it"

info "waiting up to ${REJECT_TIMEOUT}s for the poll and the rejection…"
VERDICT=""
for _ in $(seq 1 $((REJECT_TIMEOUT/5))); do
    VERDICT=$(bridge_sql "SELECT task_status FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
    [[ "$VERDICT" == "rejected" || "$VERDICT" == "accepted" ]] && break
    sleep 5
done

case "$VERDICT" in
    rejected) ok "OpenELIS wrote Task status=rejected back to the bridge" ;;
    accepted) bad "OpenELIS rejected the order" \
                  "it ACCEPTED an order whose LOINC maps to no test — the mapping guard is not working" ;;
    *)        bad "OpenELIS rejected the order" \
                  "Task still '$VERDICT' after ${REJECT_TIMEOUT}s" ;;
esac

# ---------------------------------------------------------------------------
section "5 · The verdict reaches the HIS"

STATUS=""
for _ in $(seq 1 20); do
    STATUS=$(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'")
    [[ "$STATUS" == "REJECTED_BY_LIS" ]] && break
    sleep 3
done

if [[ "$STATUS" == "REJECTED_BY_LIS" ]]; then
    ok "HIS order status is REJECTED_BY_LIS"
else
    bad "HIS order status is REJECTED_BY_LIS" "status is '$STATUS'"
fi

check_contains "The rejection reason is recorded, not just the status" \
    "his_rows \"SELECT status_detail FROM his.lab_orders WHERE order_number='$ORDER_NUMBER'\"" \
    "rejected"

check "The rejection is in the order's audit trail" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_order_events e JOIN his.lab_orders o USING (order_id)
          WHERE o.order_number='$ORDER_NUMBER' AND e.event_type='REJECTED_BY_LIS'\") -ge 1 ]]"

check_contains "lab.order.failed carried the rejection" \
    "docker exec his-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 \
       --topic ${TOPIC_ORDER_FAILED} --from-beginning --timeout-ms 12000 2>/dev/null" \
    "$ORDER_NUMBER"

check "No result was ever produced for a rejected order" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary r JOIN his.lab_orders o USING (order_id)
          WHERE o.order_number='$ORDER_NUMBER'\") == 0 ]]"

# OpenELIS does NOT discard an order it refuses — it records it as
# NonConforming (status 24) rather than Entered (21), so the lab keeps an audit
# trail of what it was sent and turned away. What must not happen is any actual
# lab work being queued against it.
check "OpenELIS recorded the refusal rather than discarding it" \
    "[[ \$(oe_sql \"SELECT count(*) FROM clinlims.electronic_order WHERE external_id='$ORDER_NUMBER'\") == 1 ]]"

check "It is NonConforming, not Entered" \
    "[[ \$(oe_sql \"SELECT s.name FROM clinlims.electronic_order e
          JOIN clinlims.status_of_sample s ON s.id = e.status_id
          WHERE e.external_id='$ORDER_NUMBER'\") == NonConforming ]]"

check "No sample or lab work was queued for it" \
    "[[ \$(oe_sql \"SELECT count(*) FROM clinlims.sample WHERE accession_number LIKE '%${ORDER_NUMBER##*-}%'\") == 0 ]]"

echo
info "Rejected order: $ORDER_NUMBER"
summary
