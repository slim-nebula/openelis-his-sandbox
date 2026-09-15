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
    # Both fixtures, and on every exit path — an early `bad ... exit 1` would
    # otherwise leave an active row offering a specimen the laboratory does not
    # accept, which the smoke suite's catalogue assertions would then trip over.
    his_sql "UPDATE his.test_catalogue SET is_active = false
              WHERE test_code IN ('$UNMAPPED_CODE', 'SPECDRIFT')" >/dev/null
    info "fixtures deactivated (catalogue rows kept: orders reference them)"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "1 · Set up catalogue drift"

# source = LOCAL, stated here rather than assumed.
#
# The column defaults to DISCOVERED, and a DISCOVERED row is one the catalogue
# sync owns and will deactivate the moment OpenELIS stops offering it — which
# for a LOINC OpenELIS has never heard of means immediately. This fixture only
# works because a sync leaves it alone.
#
# Migration 005 back-fills DRIFT to LOCAL, and that is why this went unnoticed:
# on a database with history the row already existed when the migration ran, so
# it was corrected there. On a fresh one the migration matches nothing, this
# INSERT takes the default, and the fixture quietly becomes the wrong kind of
# row. The fixture should declare what it is instead of relying on a one-off
# UPDATE having run at the right moment in the past.
his_sql "INSERT INTO his.test_catalogue
             (test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit,
              is_active, source)
         VALUES ('$UNMAPPED_CODE', 'Unmapped Drift Test', '$UNMAPPED_LOINC', 'Serum', '119364003', 'U/L',
                 true, 'LOCAL')
         ON CONFLICT (test_code) DO UPDATE SET is_active = true, source = 'LOCAL'" >/dev/null

check "HIS catalogue offers $UNMAPPED_CODE" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE test_code='$UNMAPPED_CODE' AND is_active\") == 1 ]]"

# The whole point of the test: this LOINC must resolve to nothing in the LIS.
check "No OpenELIS test carries LOINC $UNMAPPED_LOINC" \
    "[[ \$(oe_sql \"SELECT count(*) FROM clinlims.test WHERE loinc = '$UNMAPPED_LOINC'\") == 0 ]]"

# ---------------------------------------------------------------------------
section "2 · The HIS accepts the order — it cannot know the LIS will refuse"

ORDER_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$UNMAPPED_CODE\",
         \"facilityCode\":\"FAC-001\"}")
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

# ---------------------------------------------------------------------------
section "6 · A specimen the laboratory withdrew is refused BEFORE it is sent"

# The gap between the two catalogues' withdrawal semantics.
#
# When the laboratory disables one specimen variant of a test, the two sides
# forget it differently, and both are deliberate:
#
#   bridge.test_catalogue  deleted and rebuilt every sync — the row DISAPPEARS
#   his.test_catalogue     is_active = false — the row STAYS, so orders already
#                          placed against it can still resolve their test name
#
# and lab_order.bridgePayload joins on test_code WITHOUT checking is_active, for
# that same reason. So an order created while the variant was live, and still in
# flight when the sync lands, arrives at the bridge naming a (LOINC, specimen)
# pair the bridge no longer offers.
#
# That order must NOT be sent. Its LOINC is one OpenELIS still carries — on the
# OTHER specimens — so with no resolvable sample type OpenELIS binds
# alltests.get(0) and the specimen goes to the wrong bench, silently. Refusing
# is the only outcome anyone can see.
#
# Orders sit in Kafka across broker outages, delivery leases and retries, and
# the sync is manual, so this window is real rather than theoretical.
LIVE_LOINC=$(bridge_rows "SELECT loinc FROM bridge.test_catalogue
                           GROUP BY loinc HAVING count(*) > 1 ORDER BY loinc LIMIT 1")
WITHDRAWN_CODE="SPECDRIFT"

if [[ -z "$LIVE_LOINC" ]]; then
    info "no LOINC offered on more than one specimen; skipping the withdrawn-specimen check"
else
    # A specimen OpenELIS knows about but does not offer for THIS code. That is
    # exactly the shape that mis-binds: the code resolves, the specimen does not.
    ABSENT_SPECIMEN=$(oe_rows "
        SELECT tos.description FROM clinlims.type_of_sample tos
         WHERE tos.description NOT IN (
                 SELECT tos2.description
                   FROM clinlims.sampletype_test st
                   JOIN clinlims.type_of_sample tos2 ON tos2.id = st.sample_type_id
                   JOIN clinlims.test t ON t.id = st.test_id
                  WHERE t.loinc = '$LIVE_LOINC' AND t.is_active = 'Y')
         ORDER BY tos.id LIMIT 1")

    his_sql "INSERT INTO his.test_catalogue
                 (test_code, test_name, loinc_code, specimen_type, specimen_snomed,
                  is_active, source)
             VALUES ('$WITHDRAWN_CODE', 'Withdrawn Specimen Variant', '$LIVE_LOINC',
                     '$ABSENT_SPECIMEN', NULL, true, 'LOCAL')
             ON CONFLICT (test_code) DO UPDATE SET is_active = true, source = 'LOCAL',
                     loinc_code = EXCLUDED.loinc_code, specimen_type = EXCLUDED.specimen_type" >/dev/null

    info "offering $LIVE_LOINC on '$ABSENT_SPECIMEN', which the laboratory does not accept for it"

    DRIFT_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
        -d "{\"patientId\":\"11111111-1111-1111-1111-111111111111\",\"testCode\":\"$WITHDRAWN_CODE\",
             \"facilityCode\":\"FAC-001\"}")
    DRIFT_NUMBER=$(echo "$DRIFT_JSON" | json_field "['orderNumber']")

    if [[ -n "$DRIFT_NUMBER" ]]; then
        ok "HIS accepted it — it cannot know the pair is no longer offered: $DRIFT_NUMBER"

        # The assertion that matters: nothing reaches OpenELIS.
        DRIFT_TASK=""
        for _ in $(seq 1 15); do
            DRIFT_TASK=$(bridge_sql "SELECT fhir_task_id FROM bridge.order_tracking
                                      WHERE order_number = '$DRIFT_NUMBER'")
            [[ -n "$DRIFT_TASK" ]] && break
            sleep 2
        done

        if [[ -z "$DRIFT_TASK" ]]; then
            ok "The bridge did NOT publish a Task — the order never reached the laboratory"
        else
            bad "The bridge did NOT publish a Task" \
                "it published $DRIFT_TASK; OpenELIS will bind the first test on $LIVE_LOINC"
        fi

        check "The refusal is dead-lettered with a reason, not dropped" \
            "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.dead_letters
                  WHERE reason LIKE '%$LIVE_LOINC%' AND reason LIKE '%not on specimen%'\") -ge 1 ]]"

        DRIFT_STATUS=""
        for _ in $(seq 1 15); do
            DRIFT_STATUS=$(his_sql "SELECT order_status FROM his.lab_orders
                                     WHERE order_number = '$DRIFT_NUMBER'")
            [[ "$DRIFT_STATUS" == "FAILED" ]] && break
            sleep 2
        done

        if [[ "$DRIFT_STATUS" == "FAILED" ]]; then
            ok "The HIS shows it FAILED, so the doctor can re-order"
        else
            bad "The HIS shows it FAILED" "status is '$DRIFT_STATUS'"
        fi
    else
        bad "HIS accepted the withdrawn-specimen order" "$DRIFT_JSON"
    fi

    his_sql "UPDATE his.test_catalogue SET is_active = false WHERE test_code = '$WITHDRAWN_CODE'" >/dev/null
fi

echo
info "Rejected order: $ORDER_NUMBER"
summary
