#!/usr/bin/env bash
# =============================================================================
# Corrections and retractions
#
# A laboratory does not only publish results, it corrects and withdraws them.
# OpenELIS does both by UPDATING the same DiagnosticReport and incrementing
# meta.versionId, which is indistinguishable from an at-least-once redelivery
# unless the version is part of the identity being claimed.
#
# Both failures this covers were live in the system and neither was visible from
# the outside:
#
#   * a correction was suppressed as a duplicate, leaving the clinician looking
#     at the superseded value with nothing to say it had changed;
#   * a retraction never arrived at all, because entered-in-error was missing
#     from the released statuses AND because the status was read with
#     ToString(), which renders the enum member EnteredInError as
#     "enteredinerror" rather than the FHIR code "entered-in-error".
#
# The second is the reason this file exists. final, amended and corrected all
# round-trip through ToString unharmed, so every ordinary path kept working and
# only the one code that matters for patient safety silently failed.
#
#   scripts/test-corrections.sh [ORDER_NUMBER]
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_NUMBER="${1:-}"
if [[ -z "$ORDER_NUMBER" ]]; then
    ORDER_NUMBER=$(his_sql "SELECT order_number FROM his.lab_orders
                            WHERE order_status IN ('ACCEPTED_BY_LIS', 'RESULT_AVAILABLE')
                            ORDER BY created_at DESC LIMIT 1")
fi
[[ -n "$ORDER_NUMBER" ]] || { echo "No usable order. Run 'make e2e' first." >&2; exit 1; }

OUR_SR=$(bridge_sql "SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
PATIENT_FHIR=$(bridge_sql "SELECT fhir_patient_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
[[ -n "$OUR_SR" ]] || { echo "No bridge tracking row for $ORDER_NUMBER" >&2; exit 1; }

ANALYSIS_SR=$(uuidgen | tr 'A-Z' 'a-z')
OBS_ID=$(uuidgen | tr 'A-Z' 'a-z')
DR_ID=$(uuidgen | tr 'A-Z' 'a-z')
REF="DiagnosticReport/$DR_ID"

info "order $ORDER_NUMBER  report $REF"

push() {  # push <Type> <id> <json>
    docker exec -i bridge curl -fsS -X PUT \
        -H 'Content-Type: application/fhir+json' \
        --data-binary @- -o /dev/null \
        "http://127.0.0.1:8080/fhir/$1/$2" <<< "$3"
}

observation() {  # observation <versionId> <status> <value>
    echo "{
      \"resourceType\":\"Observation\",\"id\":\"$OBS_ID\",
      \"meta\":{\"versionId\":\"$1\"},
      \"status\":\"$2\",
      \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"718-7\"}]},
      \"basedOn\":[{\"reference\":\"ServiceRequest/$ANALYSIS_SR\"}],
      \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
      \"valueQuantity\":{\"value\":$3,\"unit\":\"g/dl\"}}"
}

report() {  # report <versionId> <status>
    echo "{
      \"resourceType\":\"DiagnosticReport\",\"id\":\"$DR_ID\",
      \"meta\":{\"versionId\":\"$1\"},
      \"status\":\"$2\",
      \"code\":{\"coding\":[{\"system\":\"http://loinc.org\",\"code\":\"718-7\"}]},
      \"basedOn\":[{\"reference\":\"ServiceRequest/$ANALYSIS_SR\"}],
      \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"},
      \"result\":[{\"reference\":\"Observation/$OBS_ID\"}],
      \"issued\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
}

# The correlator sweeps on a timer, so every assertion waits for the sweep
# rather than assuming it has already run.
await() {  # await <sql> <expected> [seconds]
    local want="$2" limit="${3:-45}" elapsed=0
    while (( elapsed < limit )); do
        [[ "$(his_sql "$1")" == "$want" ]] && return 0
        sleep 3; elapsed=$((elapsed + 3))
    done
    return 1
}

VALUE_SQL="SELECT coalesce(result_value,'NULL') FROM his.lab_results_summary WHERE openelis_result_ref = '$REF'"
STATUS_SQL="SELECT result_status FROM his.lab_results_summary WHERE openelis_result_ref = '$REF'"
VERSIONS_SQL="SELECT count(*) FROM bridge.forwarded_results WHERE openelis_result_ref = '$REF'"

# --- 1. the original result -------------------------------------------------
section "1 · the original result is released"
push ServiceRequest "$ANALYSIS_SR" "{
  \"resourceType\":\"ServiceRequest\",\"id\":\"$ANALYSIS_SR\",
  \"meta\":{\"versionId\":\"1\"},\"status\":\"completed\",\"intent\":\"order\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$OUR_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"}}" \
  && ok "per-analysis ServiceRequest accepted" || bad "per-analysis ServiceRequest accepted"

push Observation "$OBS_ID" "$(observation 1 final 13.8)" >/dev/null
push DiagnosticReport "$DR_ID" "$(report 1 final)" >/dev/null

await "$VALUE_SQL" "13.8" && ok "HIS shows 13.8" || bad "HIS shows 13.8" "got $(his_sql "$VALUE_SQL")"
check "status is final" "[[ \$(his_sql \"$STATUS_SQL\") == final ]]"

# --- 2. the correction ------------------------------------------------------
# The clinically important case: a value that was reported normal and is
# corrected to one below the reference range.
section "2 · a correction overwrites it"
push Observation "$OBS_ID" "$(observation 2 corrected 9.1)" >/dev/null
push DiagnosticReport "$DR_ID" "$(report 2 corrected)" >/dev/null

await "$VALUE_SQL" "9.1" && ok "HIS shows the corrected 9.1" \
    || bad "HIS shows the corrected 9.1" "got $(his_sql "$VALUE_SQL") — a correction was dropped as a duplicate"
check "status is corrected" "[[ \$(his_sql \"$STATUS_SQL\") == corrected ]]"
check "the HIS still holds exactly one row for this result" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary WHERE openelis_result_ref = '$REF'\") == 1 ]]"

# --- 3. redelivery ----------------------------------------------------------
# Kafka and the rest-hook are both at-least-once, so the same version arriving
# twice must still be suppressed. Fixing corrections must not cost idempotency.
section "3 · redelivering the same version is still suppressed"
BEFORE=$(bridge_sql "$VERSIONS_SQL")
push DiagnosticReport "$DR_ID" "$(report 2 corrected)" >/dev/null
sleep 15
check "no extra version was forwarded" \
    "[[ \$(bridge_sql \"$VERSIONS_SQL\") == $BEFORE ]]"
check "the value is unchanged" "[[ \$(his_sql \"$VALUE_SQL\") == 9.1 ]]"

# --- 4. the retraction ------------------------------------------------------
section "4 · a retraction withdraws the value"
push DiagnosticReport "$DR_ID" "$(report 3 entered-in-error)" >/dev/null

await "$STATUS_SQL" "entered-in-error" && ok "status is entered-in-error" \
    || bad "status is entered-in-error" "got $(his_sql "$STATUS_SQL") — a withdrawn result is still displayed as valid"
check "the value is cleared, not merely flagged" "[[ \$(his_sql \"$VALUE_SQL\") == NULL ]]"
check "all three versions are retained as an audit trail" \
    "[[ \$(bridge_sql \"$VERSIONS_SQL\") == 3 ]]"

summary
