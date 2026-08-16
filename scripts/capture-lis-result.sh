#!/usr/bin/env bash
# =============================================================================
# Capture ground truth: what OpenELIS ACTUALLY sends when a result is released.
#
# Run this, then release a result for the order in the OpenELIS UI. It waits for
# the push, prints the real resources, and checks them against every assumption
# the bridge's correlator makes — so the one remaining unverified link in the
# integration is settled with evidence rather than inference.
#
#   scripts/capture-lis-result.sh [ORDER_NUMBER]
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_NUMBER="${1:-}"
if [[ -z "$ORDER_NUMBER" ]]; then
    ORDER_NUMBER=$(his_sql "SELECT order_number FROM his.lab_orders
                            WHERE order_status = 'ACCEPTED_BY_LIS'
                            ORDER BY created_at DESC LIMIT 1")
fi
[[ -z "$ORDER_NUMBER" ]] && { echo "No ACCEPTED_BY_LIS order found." >&2; exit 1; }

OUR_SR=$(bridge_sql "SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
TIMEOUT="${CAPTURE_TIMEOUT:-900}"

bridge_json() {  # bridge_json <sql returning one jsonb>
    docker exec -e PGPASSWORD="$BRIDGE_DB_PASSWORD" his-db-external \
        psql -tAX -U "$BRIDGE_DB_USER" -d "$BRIDGE_DB_NAME" -c "$1" 2>/dev/null
}

cat <<EOF

  Waiting for OpenELIS to release a result for:

      order          $ORDER_NUMBER
      ServiceRequest $OUR_SR

  In OpenELIS ( https://localhost — admin / ${OE_DEFAULT_PASSWORD} ):

      1. Order -> Electronic Orders, find $ORDER_NUMBER, accession it
      2. Results -> Enter by unit, enter a value
      3. Validation, validate and release

  Waiting up to $((TIMEOUT/60)) minutes. Ctrl-C to stop.

EOF

# --- Wait for a DiagnosticReport that OpenELIS produced --------------------
# Anything already in the mirror at start is excluded, so a previously
# simulated report cannot be mistaken for the real thing.
KNOWN=$(bridge_sql "SELECT coalesce(string_agg(resource_id, ','), '') FROM bridge.received_resources WHERE resource_type='DiagnosticReport'")
info "ignoring ${KNOWN:+$(tr -cd ',' <<< "$KNOWN" | wc -c | tr -d ' ')} pre-existing DiagnosticReport(s)"

DR_ID=""
for _ in $(seq 1 $((TIMEOUT/5))); do
    DR_ID=$(bridge_sql "SELECT resource_id FROM bridge.received_resources
                        WHERE resource_type='DiagnosticReport'
                          AND resource_id <> ALL (string_to_array('$KNOWN', ','))
                        ORDER BY received_at DESC LIMIT 1")
    [[ -n "$DR_ID" ]] && break
    printf '.'
    sleep 5
done
echo

if [[ -z "$DR_ID" ]]; then
    bad "OpenELIS pushed a DiagnosticReport" "nothing arrived within $((TIMEOUT/60)) min"
    info "check: docker logs openelis-webapp | grep -iE 'subscri|export'"
    summary; exit 1
fi

ok "OpenELIS pushed DiagnosticReport/$DR_ID"

# ---------------------------------------------------------------------------
section "Ground truth — exactly what OpenELIS sent"

echo "--- DiagnosticReport/$DR_ID ---"
bridge_json "SELECT jsonb_pretty(content) FROM bridge.received_resources
             WHERE resource_type='DiagnosticReport' AND resource_id='$DR_ID'"

# ---------------------------------------------------------------------------
section "Checking the correlator's assumptions against it"

ANALYSIS_SR=$(bridge_sql "SELECT content->'basedOn'->0->>'reference' FROM bridge.received_resources
                          WHERE resource_type='DiagnosticReport' AND resource_id='$DR_ID'")
ANALYSIS_SR_ID="${ANALYSIS_SR##*/}"

if [[ -n "$ANALYSIS_SR_ID" ]]; then
    ok "DiagnosticReport.basedOn -> $ANALYSIS_SR"
else
    bad "DiagnosticReport has a basedOn reference" \
        "the correlator's first hop does not exist — correlation would rely on the identifier fallback"
fi

PARENT=$(bridge_sql "SELECT content->'basedOn'->0->>'reference' FROM bridge.received_resources
                     WHERE resource_type='ServiceRequest' AND resource_id='$ANALYSIS_SR_ID'")
if [[ -n "$PARENT" ]]; then
    ok "  its ServiceRequest.basedOn -> $PARENT"
    if [[ "${PARENT##*/}" == "$OUR_SR" ]]; then
        ok "  which is OUR ServiceRequest — the chain resolves directly"
    else
        bad "  parent is our ServiceRequest" \
            "expected $OUR_SR, got ${PARENT##*/} — correlator falls back to the order-number identifier"
    fi
else
    info "  the per-analysis ServiceRequest has not been pushed (yet) or has no basedOn"
fi

OBS=$(bridge_sql "SELECT content->'result'->0->>'reference' FROM bridge.received_resources
                  WHERE resource_type='DiagnosticReport' AND resource_id='$DR_ID'")
if [[ -n "$OBS" ]]; then
    ok "DiagnosticReport.result -> $OBS"
    echo "--- ${OBS} ---"
    bridge_json "SELECT jsonb_pretty(content) FROM bridge.received_resources
                 WHERE resource_type='Observation' AND resource_id='${OBS##*/}'"
else
    bad "DiagnosticReport references an Observation" "no result[] entries — value extraction would fall back to conclusion"
fi

DR_STATUS=$(bridge_sql "SELECT content->>'status' FROM bridge.received_resources
                        WHERE resource_type='DiagnosticReport' AND resource_id='$DR_ID'")
case "$DR_STATUS" in
    final|amended|corrected) ok "status='$DR_STATUS' — the bridge forwards this" ;;
    *) bad "status is forwardable" "status='$DR_STATUS'; the bridge only forwards final/amended/corrected" ;;
esac

# ---------------------------------------------------------------------------
section "Did it reach the HIS end to end?"

for _ in $(seq 1 20); do
    ROW=$(his_sql "SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'")
    [[ "$ROW" == "1" ]] && break
    sleep 3
done

if [[ "${ROW:-0}" == "1" ]]; then
    ok "Stored in the HIS as a simplified result"
    his_rows "SELECT '      ' || test_name || ' = ' || coalesce(result_value,'?') || ' ' || coalesce(result_unit,'') ||
                     '  [' || result_status || ']  ' || coalesce(interpretation,'no interpretation')
              FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'"
    check "Order advanced to RESULT_AVAILABLE" \
        "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number='$ORDER_NUMBER'\") == RESULT_AVAILABLE ]]"
else
    bad "Stored in the HIS as a simplified result" \
        "correlation did not complete — docker logs bridge | grep -i correlat"
fi

echo
info "Ground truth captured for $ORDER_NUMBER / DiagnosticReport/$DR_ID"
summary
