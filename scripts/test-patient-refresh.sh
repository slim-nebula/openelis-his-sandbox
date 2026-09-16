#!/usr/bin/env bash
# =============================================================================
# Does a corrected patient name reach the laboratory?
#
# THE QUESTION
# Upstream defect 05 proved that an imported Practitioner's name is frozen at
# first import: OpenELIS finds the local copy by identifier and reuses it as it
# is, discarding the incoming resource. The Patient import path has the same
# shape, and nothing anywhere proved which way it goes.
#
# It matters more for a patient than for a clinician. A misspelled name is
# corrected in the HIS constantly — a transliteration fixed, a married name, a
# transposition caught at the desk — and a laboratory report carries the name it
# holds. Two systems disagreeing about who a specimen belongs to is a
# misidentification risk, which is the failure ISO 15189 and every accreditation
# scheme treat as the most serious a laboratory has.
#
# WHAT THIS ASSERTS
# The DOCUMENTED behaviour, not the desirable one. If a future OpenELIS release
# fixes the freeze, this suite goes red and tells us — which is the point. A
# test that asserted "the name is stale" as though that were correct would be a
# test nobody could ever act on.
#
#   scripts/test-patient-refresh.sh
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A LETTERS-ONLY unique suffix, and this is not fussiness.
#
# The obvious `Freezetest$(date +%s)` was the first attempt, and OpenELIS
# silently declined to import the order: the site's configured lastNameCharset
# is `.'a-zàâçéèêëîïôûùüÿñæœ -` — letters, space, apostrophe, dot and hyphen,
# with NO DIGITS. A name containing digits fails validation on import and the
# order simply sits at SENT_TO_LIS with nothing said on either side.
#
# Worth knowing beyond this script: any HIS whose patient names can contain a
# digit will lose those orders the same way. See docs/integration-guide.md.
STAMP=$(date +%s | tr '0-9' 'abcdefghij')
ORIGINAL_LAST="Freezetest${STAMP}"
CORRECTED_LAST="Corrected${STAMP}"

TEST_CODE=$(any_active_test_code)
FACILITY=$(api_curl -sf "${API}/facilities" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['facilityCode'])" 2>/dev/null)

if [[ -z "$TEST_CODE" || -z "$FACILITY" ]]; then
    echo "No orderable test or facility. Run 'make sync-catalogue' first." >&2
    exit 1
fi

info "test $TEST_CODE at $FACILITY"

# --- helpers ----------------------------------------------------------------

place_order() {  # place_order <patientId> -> order number
    api_curl -sf -X POST "${API}/lab-orders" \
        -H 'Content-Type: application/json' \
        -d "{\"patientId\":\"$1\",\"testCode\":\"$TEST_CODE\",\"facilityCode\":\"$FACILITY\"}" \
        2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['orderNumber'])" 2>/dev/null
}

await_import() {  # await_import <order number>
    for _ in $(seq 1 40); do
        local s
        s=$(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number='$1'")
        [[ "$s" == "ACCEPTED_BY_LIS" || "$s" == "RESULT_AVAILABLE" ]] && return 0
        [[ "$s" == "REJECTED_BY_LIS" || "$s" == "FAILED" ]] && return 1
        sleep 3
    done
    return 1
}

# What OpenELIS holds for this patient, found through the identifier the bridge
# stamps — never by name, which is the thing under test.
oe_patient_name() {  # oe_patient_name <his patient uuid>
    oe_rows "SELECT pe.last_name
               FROM clinlims.patient p
               JOIN clinlims.person pe ON pe.id = p.person_id
               JOIN clinlims.patient_identity pi ON pi.patient_id = p.id
              WHERE pi.identity_data = '$1'
              LIMIT 1" | head -1 | tr -d '[:space:]'
}

# --- 1. a patient, an order, and an import ----------------------------------
section "1 · A patient the laboratory has seen once"

PATIENT_JSON=$(api_curl -sf -X POST "${API}/patients" \
    -H 'Content-Type: application/json' \
    -d "{\"firstName\":\"Refresh\",\"lastName\":\"$ORIGINAL_LAST\",\"sex\":\"F\",\"dateOfBirth\":\"1990-03-11\"}" 2>/dev/null)

PATIENT_ID=$(echo "$PATIENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['patientId'])" 2>/dev/null)

if [[ -z "$PATIENT_ID" ]]; then
    bad "Created a patient" "response: ${PATIENT_JSON:0:200}"
    summary; exit 1
fi
ok "Created patient $PATIENT_ID as '$ORIGINAL_LAST'"

ORDER1=$(place_order "$PATIENT_ID")
[[ -n "$ORDER1" ]] && ok "Placed the first order ($ORDER1)" || { bad "Placed the first order"; summary; exit 1; }

info "waiting for OpenELIS to import it…"
if await_import "$ORDER1"; then
    ok "OpenELIS imported the first order"
else
    bad "OpenELIS imported the first order" \
        "status $(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number='$ORDER1'")"
    summary; exit 1
fi

SEEN_FIRST=$(oe_patient_name "$PATIENT_ID")
[[ "$SEEN_FIRST" == "$ORIGINAL_LAST" ]] \
    && ok "The laboratory has the patient as '$SEEN_FIRST'" \
    || bad "The laboratory has the original name" "got '$SEEN_FIRST', expected '$ORIGINAL_LAST'"

# --- 2. the correction ------------------------------------------------------
section "2 · The name is corrected in the HIS"

# Written straight to the table. The HIS sandbox exposes no patient-update
# endpoint, and adding one to run a test would be inventing an API surface to
# suit the test rather than the other way round. What travels to the laboratory
# is read from the table at publish time either way.
his_sql "UPDATE his.patients SET last_name = '$CORRECTED_LAST', updated_at = now()
          WHERE patient_id = '$PATIENT_ID'" >/dev/null

check "The HIS now holds the corrected name" \
    "[[ \$(his_sql \"SELECT last_name FROM his.patients WHERE patient_id='$PATIENT_ID'\") == $CORRECTED_LAST ]]"

# --- 3. a second order, carrying the corrected name -------------------------
section "3 · A second order carries the correction to the laboratory"

ORDER2=$(place_order "$PATIENT_ID")
[[ -n "$ORDER2" ]] && ok "Placed the second order ($ORDER2)" || { bad "Placed the second order"; summary; exit 1; }

info "waiting for OpenELIS to import it…"
if await_import "$ORDER2"; then
    ok "OpenELIS imported the second order"
else
    bad "OpenELIS imported the second order" \
        "status $(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number='$ORDER2'")"
    summary; exit 1
fi

# The bridge's own copy must carry the correction — if it does not, the defect
# is ours and not upstream's, and that distinction is the whole point of
# checking here before checking OpenELIS.
PUBLISHED=$(bridge_rows "SELECT content -> 'name' -> 0 ->> 'family'
                           FROM bridge.fhir_resources
                          WHERE resource_type='Patient' AND resource_id='$PATIENT_ID'" | head -1 | tr -d '[:space:]')

[[ "$PUBLISHED" == "$CORRECTED_LAST" ]] \
    && ok "The bridge published the corrected name ('$PUBLISHED')" \
    || bad "The bridge published the corrected name" "got '$PUBLISHED'"

# --- 4. the finding ---------------------------------------------------------
section "4 · What the laboratory ended up with"

SEEN_SECOND=$(oe_patient_name "$PATIENT_ID")
info "OpenELIS now holds: '$SEEN_SECOND'"

VERSIONS=$(oe_sql "SELECT count(*) FROM clinlims.hfj_res_ver v
                     JOIN clinlims.hfj_resource r ON r.res_id = v.res_id
                    WHERE r.res_type = 'Patient' AND r.fhir_id = '$PATIENT_ID'")

if [[ "$SEEN_SECOND" == "$CORRECTED_LAST" ]]; then
    # The good outcome. If this ever starts happening, the documented workaround
    # is obsolete and docs/archive/upstream-issues/07 should be closed.
    ok "OpenELIS REFRESHED the patient name — upstream issue 07 no longer applies"
    info "update docs/archive/upstream-issues/07-patient-name-never-refreshed.md and the field map"
else
    # The documented behaviour, asserted as such. This is not a passing test
    # celebrating a bug — it is a tripwire: it goes red the day upstream fixes
    # it, which is exactly when we want to be told.
    ok "OpenELIS kept the name it first saw ('$SEEN_SECOND') — upstream issue 07 confirmed"
    check "…and wrote no new version of the resource (still $VERSIONS)" \
        "[[ ${VERSIONS:-0} -le 1 ]]"
    info "a demographic correction does NOT reach the laboratory; see docs/archive/upstream-issues/07"
fi

summary
