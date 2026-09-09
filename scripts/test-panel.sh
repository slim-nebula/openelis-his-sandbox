#!/usr/bin/env bash
# =============================================================================
# Panel results — a report with more than one analyte
#
# THE DEFECT THIS SUITE EXISTS TO KEEP CLOSED
# A DiagnosticReport may reference several Observations: eight for a full blood
# count, four for an electrolyte panel. The bridge used to forward the FIRST one
# and silently drop the rest, so a HIS reading the projection saw one number
# where the laboratory had released eight. Nothing failed and nothing was
# logged — the result looked complete.
#
# Every test on the sandbox's menu is single-analyte, which is why this never
# surfaced in the other suites and why it needs one of its own: the shape has to
# be exercised deliberately before a laboratory offers a panel.
#
# SCOPE, stated honestly, and the same as test-result-return.sh: this does not
# drive OpenELIS's workflow. It delivers resources to the bridge's real FHIR
# endpoint over the same rest-hook mechanism OpenELIS uses, shaped as OpenELIS
# shapes them, and asserts what the bridge and the HIS do with them.
#
#   scripts/test-panel.sh [ORDER_NUMBER]
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_NUMBER="${1:-}"
if [[ -z "$ORDER_NUMBER" ]]; then
    ORDER_NUMBER=$(his_sql "SELECT order_number FROM his.lab_orders
                            WHERE order_status IN ('ACCEPTED_BY_LIS', 'RESULT_AVAILABLE')
                            ORDER BY created_at DESC LIMIT 1")
fi

if [[ -z "$ORDER_NUMBER" ]]; then
    echo "No order the laboratory has accepted. Run 'make e2e' first." >&2
    exit 1
fi

OUR_SR=$(bridge_sql "SELECT fhir_servicerequest_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
PATIENT_FHIR=$(bridge_sql "SELECT fhir_patient_id FROM bridge.order_tracking WHERE order_number = '$ORDER_NUMBER'")
PATIENT_UUID=$(his_sql "SELECT patient_id FROM his.lab_orders WHERE order_number='$ORDER_NUMBER'")

if [[ -z "$OUR_SR" ]]; then
    echo "No bridge tracking row for $ORDER_NUMBER" >&2
    exit 1
fi

ANALYSIS_SR=$(uuidgen | tr 'A-Z' 'a-z')
DR_ID=$(uuidgen | tr 'A-Z' 'a-z')
ISSUED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Three analytes of a fictitious panel. The middle one is CRITICALLY high on
# purpose: a panel whose every component is normal would not prove that severity
# survives per component, which is the property that matters clinically.
HGB_OBS=$(uuidgen | tr 'A-Z' 'a-z')
WBC_OBS=$(uuidgen | tr 'A-Z' 'a-z')
PLT_OBS=$(uuidgen | tr 'A-Z' 'a-z')

info "order $ORDER_NUMBER  our ServiceRequest $OUR_SR"
info "simulating a three-analyte panel: DiagnosticReport/$DR_ID"

push() {  # push <Type> <id> <json>
    docker exec -i bridge curl -fsS -X PUT \
        -H 'Content-Type: application/fhir+json' \
        --data-binary @- -o /dev/null \
        "http://127.0.0.1:8080/fhir/$1/$2" <<< "$3"
}

observation() {  # observation <id> <loinc> <display> <value> <unit> <low> <high> <interpCode> <interpDisplay>
    cat <<JSON
{
  "resourceType":"Observation","id":"$1",
  "status":"final",
  "basedOn":[{"reference":"ServiceRequest/$ANALYSIS_SR"}],
  "subject":{"reference":"Patient/$PATIENT_FHIR"},
  "code":{"coding":[{"system":"http://loinc.org","code":"$2","display":"$3"}],"text":"$3"},
  "valueQuantity":{"value":$4,"unit":"$5","system":"http://unitsofmeasure.org","code":"$5"},
  "interpretation":[{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation","code":"$8","display":"$9"}]}],
  "referenceRange":[{"low":{"value":$6},"high":{"value":$7}}]
}
JSON
}

report() {  # report <status> <extra-result-refs...>
    local status="$1"; shift
    local refs=""
    for id in "$@"; do
        [[ -n "$refs" ]] && refs="$refs,"
        refs="$refs{\"reference\":\"Observation/$id\"}"
    done
    cat <<JSON
{
  "resourceType":"DiagnosticReport","id":"$DR_ID",
  "status":"$status",
  "basedOn":[{"reference":"ServiceRequest/$ANALYSIS_SR"}],
  "subject":{"reference":"Patient/$PATIENT_FHIR"},
  "code":{"coding":[{"system":"http://loinc.org","code":"58410-2","display":"Full blood count panel"}],"text":"Full blood count panel"},
  "issued":"$ISSUED",
  "result":[$refs]
}
JSON
}

component_count() {
    his_sql "SELECT count(*) FROM his.lab_result_components k
               JOIN his.lab_results_summary r ON r.result_id = k.result_id
              WHERE r.openelis_result_ref = 'DiagnosticReport/$DR_ID'"
}

await_result() {  # await_result <expected component count>
    for _ in $(seq 1 20); do
        [[ "$(component_count)" == "$1" ]] && return 0
        sleep 3
    done
    return 1
}

# ---------------------------------------------------------------------------
section "1 · The chain, and the analytes"

push ServiceRequest "$ANALYSIS_SR" "{
  \"resourceType\":\"ServiceRequest\",\"id\":\"$ANALYSIS_SR\",
  \"status\":\"completed\",\"intent\":\"order\",
  \"basedOn\":[{\"reference\":\"ServiceRequest/$OUR_SR\"}],
  \"subject\":{\"reference\":\"Patient/$PATIENT_FHIR\"}
}" && ok "per-analysis ServiceRequest accepted" || bad "per-analysis ServiceRequest accepted"

push Observation "$HGB_OBS" "$(observation "$HGB_OBS" 718-7  'Haemoglobin'    12.9 'g/dL'    12 16 N  Normal)" \
    && ok "Observation 1 of 3 accepted (haemoglobin, normal)" || bad "Observation 1 accepted"
push Observation "$WBC_OBS" "$(observation "$WBC_OBS" 6690-2 'Leukocytes'     31.4 '10*3/uL' 4  11 HH 'Critical high')" \
    && ok "Observation 2 of 3 accepted (leukocytes, CRITICAL)" || bad "Observation 2 accepted"
push Observation "$PLT_OBS" "$(observation "$PLT_OBS" 777-3  'Platelet count' 189  '10*3/uL' 150 400 N Normal)" \
    && ok "Observation 3 of 3 accepted (platelets, normal)" || bad "Observation 3 accepted"

# ---------------------------------------------------------------------------
section "2 · The whole report reaches the HIS, not just its first analyte"

push DiagnosticReport "$DR_ID" "$(report final "$HGB_OBS" "$WBC_OBS" "$PLT_OBS")" \
    && ok "DiagnosticReport accepted" || bad "DiagnosticReport accepted"

info "waiting for the correlation sweep…"
if await_result 3; then
    ok "All three analytes stored, not one"
else
    bad "All three analytes stored" \
        "got $(component_count) component(s). docker logs bridge | grep -i observation"
    summary; exit 1
fi

# The exact contents, in order. A count alone would pass on three rows that all
# held the first analyte's value — which is precisely the bug, one layer along.
#
# Read one position at a time rather than into an array: macOS ships bash 3.2,
# which has no mapfile, and every suite here has to run on the machine the
# developers actually have.
component_at() {  # component_at <position>
    his_rows "SELECT k.position || '|' || coalesce(k.analyte_code,'-') || '|' || k.analyte_name
                     || '|' || coalesce(k.result_value,'-') || '|' || coalesce(k.result_unit,'-')
                     || '|' || coalesce(k.interpretation_code,'-')
                FROM his.lab_result_components k
                JOIN his.lab_results_summary r ON r.result_id = k.result_id
               WHERE r.openelis_result_ref = 'DiagnosticReport/$DR_ID'
                 AND k.position = $1" | head -1
}

ROW0=$(component_at 0); ROW1=$(component_at 1); ROW2=$(component_at 2)

[[ "$ROW0" == "0|718-7|Haemoglobin|12.9|g/dL|N" ]] \
    && ok "Component 0 is haemoglobin, with its own value and unit" \
    || bad "Component 0 correct" "got '$ROW0'"

[[ "$ROW1" == "1|6690-2|Leukocytes|31.4|10*3/uL|HH" ]] \
    && ok "Component 1 is leukocytes, with its own value and unit" \
    || bad "Component 1 correct" "got '$ROW1'"

[[ "$ROW2" == "2|777-3|Platelet count|189|10*3/uL|N" ]] \
    && ok "Component 2 is platelets, with its own value and unit" \
    || bad "Component 2 correct" "got '$ROW2'"

# The clinical point of a panel. Six normal analytes and one critical is the
# ordinary case, and the critical one is the entire reason the report matters —
# so severity has to live per component, not per report.
# k.interpretation_code, not interpretation_code. The column exists on BOTH
# tables — the report has one and so does each analyte — so the unqualified name
# is ambiguous and the query errors. his_sql swallows stderr, so an unqualified
# column here fails as an empty string and reads exactly like a missing value.
CRITICAL_CODE=$(his_sql "SELECT k.interpretation_code FROM his.lab_result_components k
                           JOIN his.lab_results_summary r ON r.result_id = k.result_id
                          WHERE r.openelis_result_ref = 'DiagnosticReport/$DR_ID' AND k.position = 1")
[[ "$CRITICAL_CODE" == "HH" ]] \
    && ok "A critical analyte keeps its own HH code inside an otherwise normal panel" \
    || bad "A critical analyte keeps its own HH code" "got '$CRITICAL_CODE'"

# ---------------------------------------------------------------------------
section "3 · The flat fields still answer, for a consumer that predates panels"

# The compatibility view. A caller written before panels existed reads
# resultValue and must still get a sensible answer rather than null — the FIRST
# analyte, which is what the report-level fields have always meant.
check "Report-level resultValue is the first analyte, not null" \
    "[[ \$(his_sql \"SELECT result_value FROM his.lab_results_summary
           WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'\") == 12.9 ]]"

check "Report-level unit matches that same analyte" \
    "[[ \$(his_sql \"SELECT result_unit FROM his.lab_results_summary
           WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'\") == g/dL ]]"

check "One result row, not one per analyte" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary
           WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "4 · The API serves the components"

RESULTS_JSON=$(api_curl -sf "${API}/patients/$PATIENT_UUID/results")

check_contains "Components are exposed on the result" "echo '$RESULTS_JSON'" '"components"'
check_contains "…naming the analyte"                  "echo '$RESULTS_JSON'" '"analyteName":"Leukocytes"'
check_contains "…carrying its own value"              "echo '$RESULTS_JSON'" '"resultValue":"31.4"'
check_contains "…and its own severity code"           "echo '$RESULTS_JSON'" '"interpretationCode":"HH"'

# Ordering is part of the contract: a haemogram read out of order is harder to
# read, and for a differential count actively misleading.
check "Components arrive in the order the laboratory released them" \
    "python3 -c \"
import json,sys
rs=json.loads(sys.stdin.read())
r=[x for x in rs if x['openelisResultRef']=='DiagnosticReport/$DR_ID'][0]
names=[c['analyteName'] for c in r['components']]
assert names==['Haemoglobin','Leukocytes','Platelet count'], names
\" <<< '$RESULTS_JSON'"

# ---------------------------------------------------------------------------
section "5 · Redelivery does not accumulate"

# OpenELIS re-pushes a report whenever anything about it changes. Components are
# deleted and rewritten on every upsert, so a replay must leave three rows and
# not six — the failure that would otherwise show a patient's haemoglobin twice.
push DiagnosticReport "$DR_ID" "$(report final "$HGB_OBS" "$WBC_OBS" "$PLT_OBS")"
sleep 15
check "Re-pushing the same panel still leaves three components" \
    "[[ \$(component_count) == 3 ]]"

# ---------------------------------------------------------------------------
section "6 · A correction replaces the analytes rather than merging them"

# A corrected report is a new statement about EVERY analyte in it. Merging
# component by component would leave an analyte the laboratory withdrew still
# on the screen, sourced from a report that no longer contains it.
#
# This correction drops platelets entirely and changes the leukocyte count.
CORRECTED_WBC=$(uuidgen | tr 'A-Z' 'a-z')
push Observation "$CORRECTED_WBC" "$(observation "$CORRECTED_WBC" 6690-2 'Leukocytes' 9.2 '10*3/uL' 4 11 N Normal)" \
    && ok "corrected leukocyte Observation accepted" || bad "corrected Observation accepted"

docker exec -i bridge curl -fsS -X PUT \
    -H 'Content-Type: application/fhir+json' --data-binary @- -o /dev/null \
    "http://127.0.0.1:8080/fhir/DiagnosticReport/$DR_ID" <<JSON
{
  "resourceType":"DiagnosticReport","id":"$DR_ID",
  "meta":{"versionId":"2"},
  "status":"corrected",
  "basedOn":[{"reference":"ServiceRequest/$ANALYSIS_SR"}],
  "subject":{"reference":"Patient/$PATIENT_FHIR"},
  "code":{"coding":[{"system":"http://loinc.org","code":"58410-2"}],"text":"Full blood count panel"},
  "issued":"$ISSUED",
  "result":[{"reference":"Observation/$HGB_OBS"},{"reference":"Observation/$CORRECTED_WBC"}]
}
JSON

if await_result 2; then
    ok "The correction left two components, not five"
else
    bad "Correction replaces the component set" "got $(component_count) component(s)"
fi

check "The withdrawn analyte is gone, not merely superseded" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_result_components k
            JOIN his.lab_results_summary r ON r.result_id = k.result_id
           WHERE r.openelis_result_ref = 'DiagnosticReport/$DR_ID'
             AND k.analyte_code = '777-3'\") == 0 ]]"

# Qualified for the same reason as the interpretation code above: result_value
# is a column on both tables.
CORRECTED_VALUE=$(his_sql "SELECT k.result_value FROM his.lab_result_components k
                             JOIN his.lab_results_summary r ON r.result_id = k.result_id
                            WHERE r.openelis_result_ref = 'DiagnosticReport/$DR_ID'
                              AND k.analyte_code = '6690-2'")
[[ "$CORRECTED_VALUE" == "9.2" ]] \
    && ok "The corrected value replaced the old one" \
    || bad "The corrected value replaced the old one" "got '$CORRECTED_VALUE'"

# The components must hang off the row that is actually visible. lab_results_summary
# upserts, so a correction keeps the ORIGINAL result_id and discards the uuid
# minted for that pass — writing components against the discarded one would
# orphan them: the correction's analytes attached to nothing, the superseded
# ones still attached to the row on screen.
check "Components belong to the surviving result row, not an orphaned one" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_result_components k
           WHERE NOT EXISTS (SELECT 1 FROM his.lab_results_summary r
                              WHERE r.result_id = k.result_id)\") == 0 ]]"

# ---------------------------------------------------------------------------
section "7 · A retraction withdraws every analyte"

# Leaving components behind on a retracted report would be the worst of both:
# the row says "withdrawn" while the analytes underneath still show numbers a
# clinician can read and act on.
docker exec -i bridge curl -fsS -X PUT \
    -H 'Content-Type: application/fhir+json' --data-binary @- -o /dev/null \
    "http://127.0.0.1:8080/fhir/DiagnosticReport/$DR_ID" <<JSON
{
  "resourceType":"DiagnosticReport","id":"$DR_ID",
  "meta":{"versionId":"3"},
  "status":"entered-in-error",
  "basedOn":[{"reference":"ServiceRequest/$ANALYSIS_SR"}],
  "subject":{"reference":"Patient/$PATIENT_FHIR"},
  "code":{"coding":[{"system":"http://loinc.org","code":"58410-2"}],"text":"Full blood count panel"},
  "issued":"$ISSUED",
  "result":[{"reference":"Observation/$HGB_OBS"},{"reference":"Observation/$CORRECTED_WBC"}]
}
JSON

if await_result 0; then
    ok "A retraction clears the analytes as well as the value"
else
    bad "Retraction clears components" "got $(component_count) component(s) still showing"
fi

check "…and the report itself is marked entered-in-error" \
    "[[ \$(his_sql \"SELECT result_status FROM his.lab_results_summary
           WHERE openelis_result_ref = 'DiagnosticReport/$DR_ID'\") == entered-in-error ]]"

# ---------------------------------------------------------------------------
section "8 · An incomplete panel waits rather than arriving truncated"

# THE SUBTLE ONE. OpenELIS pushes a report's Observations in separate
# deliveries, so a panel routinely arrives before its components. The forward is
# claimed once per (report, version) — so publishing early is FINAL, and the
# analytes still in flight would arrive to find the version already forwarded
# and be dropped for ever.
#
# A report referencing an Observation the bridge has never seen must therefore
# be left for the next sweep, not forwarded with a hole in it.
PARTIAL_DR=$(uuidgen | tr 'A-Z' 'a-z')
GHOST_OBS=$(uuidgen | tr 'A-Z' 'a-z')     # deliberately never pushed
ARRIVED_OBS=$(uuidgen | tr 'A-Z' 'a-z')

push Observation "$ARRIVED_OBS" "$(observation "$ARRIVED_OBS" 718-7 'Haemoglobin' 13.1 'g/dL' 12 16 N Normal)" >/dev/null

docker exec -i bridge curl -fsS -X PUT \
    -H 'Content-Type: application/fhir+json' --data-binary @- -o /dev/null \
    "http://127.0.0.1:8080/fhir/DiagnosticReport/$PARTIAL_DR" <<JSON
{
  "resourceType":"DiagnosticReport","id":"$PARTIAL_DR",
  "status":"final",
  "basedOn":[{"reference":"ServiceRequest/$ANALYSIS_SR"}],
  "subject":{"reference":"Patient/$PATIENT_FHIR"},
  "code":{"coding":[{"system":"http://loinc.org","code":"58410-2"}],"text":"Full blood count panel"},
  "issued":"$ISSUED",
  "result":[{"reference":"Observation/$ARRIVED_OBS"},{"reference":"Observation/$GHOST_OBS"}]
}
JSON

sleep 20
check "A report whose Observations have not all arrived is NOT forwarded yet" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_results_summary
           WHERE openelis_result_ref = 'DiagnosticReport/$PARTIAL_DR'\") == 0 ]]"

check "…and it is left unprocessed so a later sweep can complete it" \
    "[[ \$(bridge_sql \"SELECT processed FROM bridge.received_resources
           WHERE resource_type='DiagnosticReport' AND resource_id='$PARTIAL_DR'\") == f ]]"

# And the other half of the rule: once the straggler lands, the whole panel goes.
push Observation "$GHOST_OBS" "$(observation "$GHOST_OBS" 777-3 'Platelet count' 201 '10*3/uL' 150 400 N Normal)" >/dev/null

FOUND=""
for _ in $(seq 1 20); do
    if [[ $(his_sql "SELECT count(*) FROM his.lab_result_components k
              JOIN his.lab_results_summary r ON r.result_id = k.result_id
             WHERE r.openelis_result_ref = 'DiagnosticReport/$PARTIAL_DR'") == "2" ]]; then
        FOUND=yes; break
    fi
    sleep 3
done

[[ -n "$FOUND" ]] \
    && ok "Once the late Observation arrives, the complete panel is forwarded" \
    || bad "Late Observation completes the panel" \
           "still $(his_sql "SELECT count(*) FROM his.lab_result_components k
              JOIN his.lab_results_summary r ON r.result_id = k.result_id
             WHERE r.openelis_result_ref = 'DiagnosticReport/$PARTIAL_DR'") component(s)"

# ---------------------------------------------------------------------------
section "9 · A single-analyte result is unchanged"

# The regression guard. Every existing test on the menu is single-analyte, and
# this whole change must be invisible to them: one component, whose values equal
# the flat fields the rest of the system has always read.
SINGLE_DR=$(uuidgen | tr 'A-Z' 'a-z')
SINGLE_OBS=$(uuidgen | tr 'A-Z' 'a-z')

push Observation "$SINGLE_OBS" "$(observation "$SINGLE_OBS" 2345-7 'Glucose' 5.4 'mmol/L' 3.9 5.8 N Normal)" >/dev/null
docker exec -i bridge curl -fsS -X PUT \
    -H 'Content-Type: application/fhir+json' --data-binary @- -o /dev/null \
    "http://127.0.0.1:8080/fhir/DiagnosticReport/$SINGLE_DR" <<JSON
{
  "resourceType":"DiagnosticReport","id":"$SINGLE_DR",
  "status":"final",
  "basedOn":[{"reference":"ServiceRequest/$ANALYSIS_SR"}],
  "subject":{"reference":"Patient/$PATIENT_FHIR"},
  "code":{"coding":[{"system":"http://loinc.org","code":"2345-7"}],"text":"Glucose"},
  "issued":"$ISSUED",
  "result":[{"reference":"Observation/$SINGLE_OBS"}]
}
JSON

SINGLE_OK=""
for _ in $(seq 1 20); do
    if [[ $(his_sql "SELECT count(*) FROM his.lab_results_summary
             WHERE openelis_result_ref = 'DiagnosticReport/$SINGLE_DR'") == "1" ]]; then
        SINGLE_OK=yes; break
    fi
    sleep 3
done

[[ -n "$SINGLE_OK" ]] && ok "A single-analyte result still lands" || bad "Single-analyte result lands"

check "It carries exactly one component" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_result_components k
            JOIN his.lab_results_summary r ON r.result_id = k.result_id
           WHERE r.openelis_result_ref = 'DiagnosticReport/$SINGLE_DR'\") == 1 ]]"

check "…whose value equals the report-level value the rest of the system reads" \
    "[[ \$(his_sql \"SELECT k.result_value = r.result_value FROM his.lab_result_components k
            JOIN his.lab_results_summary r ON r.result_id = k.result_id
           WHERE r.openelis_result_ref = 'DiagnosticReport/$SINGLE_DR'\") == t ]]"

summary
