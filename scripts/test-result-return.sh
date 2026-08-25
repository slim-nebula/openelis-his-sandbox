#!/usr/bin/env bash
# =============================================================================
# Result return path — bridge correlation and HIS projection
#
# SCOPE, stated honestly: this does NOT drive OpenELIS's lab workflow. It
# delivers DiagnosticReport / Observation / ServiceRequest resources to the
# bridge's real FHIR endpoint over the same rest-hook mechanism OpenELIS uses,
# shaped exactly as OpenELIS shapes them:
#
#     DiagnosticReport.basedOn -> ServiceRequest (per analysis)
#                                   `- .basedOn -> ServiceRequest (ours)
#
# It exercises the bridge's correlation walk, the HIS projection and the
# idempotency guards. Proving that OpenELIS itself emits these on release is
# what the manual step in test-order-flow.sh covers.
#
#   scripts/test-result-return.sh [ORDER_NUMBER]
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_NUMBER="${1:-}"
if [[ -z "$ORDER_NUMBER" ]]; then
    ORDER_NUMBER=$(his_sql "SELECT order_number FROM his.lab_orders
                            WHERE order_status = 'ACCEPTED_BY_LIS'
                            ORDER BY created_at DESC LIMIT 1")
fi

if [[ -z "$ORDER_NUMBER" ]]; then
    echo "No order in ACCEPTED_BY_LIS state. Run 'make e2e' first." >&2
    exit 1
fi

OUR_SR=$(bridge_sql "SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
PATIENT_FHIR=$(bridge_sql "SELECT fhir_patient_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")

if [[ -z "$OUR_SR" ]]; then
    echo "No bridge tracking row for $ORDER_NUMBER" >&2
    exit 1
fi

ANALYSIS_SR=$(uuidgen | tr 'A-Z' 'a-z')
OBS_ID=$(uuidgen | tr 'A-Z' 'a-z')
DR_ID=$(uuidgen | tr 'A-Z' 'a-z')
ISSUED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

info "order $ORDER_NUMBER  our ServiceRequest $OUR_SR"
info "simulating OpenELIS release: DiagnosticReport/$DR_ID -> ServiceRequest/$ANALYSIS_SR -> ServiceRequest/$OUR_SR"

# Delivered exactly as OpenELIS's rest-hook subscription delivers: PUT of a
# single resource to {subscriber}/{Type}/{id}.
push() {  # push <Type> <id> <json>
    docker exec -i bridge curl -fsS -X PUT \
        -H 'Content-Type: application/fhir+json' \
        --data-binary @- -o /dev/null \
        "http://127.0.0.1:8080/fhir/$1/$2" <<< "$3"
}

section "1 · OpenELIS pushes the per-analysis ServiceRequest"
push ServiceRequest "$ANALYSIS_SR" "{
  \"resourceType\":\"ServiceRequest\",\"id\":\"$ANALYSIS_SR\",
  \"status\":\"completed\",\"intent\":\"order\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$OUR_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"}
}" && ok "per-analysis ServiceRequest accepted" || bad "per-analysis ServiceRequest accepted"

section "2 · OpenELIS pushes the Observation"
push Observation "$OBS_ID" "{
  \"resourceType\":\"Observation\",\"id\":\"$OBS_ID\",
  \"status\":\"final\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$ANALYSIS_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
  \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"2345-7\",\"display\":\"Glucose\"}]},
  \"valueQuantity\":{\"value\":5.4,\"unit\":\"mmol/L\",\"system\":\"http://unitsofmeasure.org\",\"code\":\"mmol/L\"},
  \"interpretation\":[{\"coding\":[{\"system\":\"http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation\",\"code\":\"N\",\"display\":\"Normal\"}]}],
  \"referenceRange\":[{\"low\":{\"value\":3.9},\"high\":{\"value\":5.8}}]
}" && ok "Observation accepted" || bad "Observation accepted"

section "3 · OpenELIS pushes the released DiagnosticReport"
push DiagnosticReport "$DR_ID" "{
  \"resourceType\":\"DiagnosticReport\",\"id\":\"$DR_ID\",
  \"status\":\"final\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$ANALYSIS_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
  \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"2345-7\",\"display\":\"Glucose\"}],\"text\":\"Glucose\"},
  \"issued\":\"$ISSUED\",
  \"result\":[{\"reference\":\"Observation/$OBS_ID\"}]
}" && ok "DiagnosticReport accepted" || bad "DiagnosticReport accepted"

section "4 · Bridge correlates it back to the HIS order"
info "waiting for the correlation sweep…"
FOUND=""
for _ in $(seq 1 20); do
    if [[ $(his_sql "SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'") == "1" ]]; then
        FOUND=yes; break
    fi
    sleep 3
done

if [[ -n "$FOUND" ]]; then
    ok "Released result correlated and stored in the HIS sandbox database"
else
    bad "Released result correlated and stored" \
        "nothing arrived. docker logs bridge | grep -i correlat"
    summary; exit 1
fi

section "5 · The projection is correct"
read -r VALUE UNIT INTERP RANGE STATUS <<< "$(his_rows "
    SELECT result_value || ' ' || coalesce(result_unit,'-') || ' ' ||
           coalesce(interpretation,'-') || ' ' || coalesce(reference_range,'-') || ' ' || result_status
    FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'")"

[[ "$VALUE"  == "5.4"    ]] && ok "value flattened from valueQuantity: $VALUE" || bad "value flattened" "got '$VALUE'"
[[ "$UNIT"   == "mmol/L" ]] && ok "unit carried through: $UNIT"                || bad "unit carried through" "got '$UNIT'"
[[ "$INTERP" == "Normal" ]] && ok "interpretation resolved: $INTERP"           || bad "interpretation resolved" "got '$INTERP'"
[[ "$RANGE"  == "3.9-5.8" ]] && ok "reference range formatted: $RANGE"         || bad "reference range" "got '$RANGE'"
[[ "$STATUS" == "final"  ]] && ok "status is final"                            || bad "status is final" "got '$STATUS'"

check "Order advanced to RESULT_AVAILABLE" \
    "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number = '$ORDER_NUMBER'\") == RESULT_AVAILABLE ]]"

check "Result keeps its back-reference to the OpenELIS record" \
    "[[ \$(his_sql \"SELECT openelis_result_ref FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'\") == DiagnosticReport/$DR_ID ]]"

check "Frontend can read it through the gateway" \
    "api_curl -sf ${API}/patients/\$(his_sql \"SELECT patient_id FROM his.lab_orders WHERE order_number='$ORDER_NUMBER'\")/results | grep -q '$DR_ID'"

# ---------------------------------------------------------------------------
section "5b · The result says where to file it"

# The whole point of the return path. Knowing WHICH PATIENT is not enough to
# file a result — one visit can hold several orders, so the result has to say
# which encounter it belongs to as well.
#
# The file number is deliberately not carried: the calling HIS owns the patient
# record and resolves it from patient_id, so sending it would be a second copy
# of something the caller already holds, arriving by a longer route.
#
# Note what makes the visit work: it is never sent to OpenELIS and never comes
# back from it. The result is matched to its ORDER first, and the order is the
# thing that remembers the encounter — so the laboratory cannot lose or alter it.
VISIT="VISIT-RR-$(date +%s)"
his_sql "UPDATE his.lab_orders SET visit_number = '$VISIT'
          WHERE order_number = '$ORDER_NUMBER'" >/dev/null

RESULT_JSON=$(api_curl -sf "${API}/patients/$(his_sql "SELECT patient_id FROM his.lab_orders \
    WHERE order_number='$ORDER_NUMBER'")/results")

check_contains "Result carries the visit it was ordered during" \
    "echo '$RESULT_JSON'" "$VISIT"

# And the question a clinician opening an encounter actually asks.
check_contains "Results are retrievable by visit" \
    "api_curl -sf '${API}/visits/$VISIT/results'" "$DR_ID"

check "A visit with no orders returns an empty list, not an error" \
    "[[ \$(api_curl -sf '${API}/visits/VISIT-NOT-A-REAL-ONE/results') == '[]' ]]"

section "6 · Redelivery is idempotent"
push DiagnosticReport "$DR_ID" "{
  \"resourceType\":\"DiagnosticReport\",\"id\":\"$DR_ID\",
  \"status\":\"final\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$ANALYSIS_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
  \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"2345-7\"}],\"text\":\"Glucose\"},
  \"issued\":\"$ISSUED\",
  \"result\":[{\"reference\":\"Observation/$OBS_ID\"}]
}"
sleep 15
check "Re-pushing the same report does not duplicate the projection" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'\") == 1 ]]"

section "7 · Unvalidated results stay in the lab"
PRELIM_ID=$(uuidgen | tr 'A-Z' 'a-z')
push DiagnosticReport "$PRELIM_ID" "{
  \"resourceType\":\"DiagnosticReport\",\"id\":\"$PRELIM_ID\",
  \"status\":\"preliminary\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$ANALYSIS_SR\"}],
  \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"2345-7\"}]},
  \"issued\":\"$ISSUED\",
  \"result\":[{\"reference\":\"Observation/$OBS_ID\"}]
}"
sleep 15
check "A preliminary report is not forwarded to the HIS" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = 'DiagnosticReport/$PRELIM_ID'\") == 0 ]]"

summary
