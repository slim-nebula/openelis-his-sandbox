#!/usr/bin/env bash
# =============================================================================
# The ordering clinician, from the doctor's screen to the laboratory's
#
# WHY THIS EXISTS
# CLIA 42 CFR 493.1291(a) and ISO 15189:2022 7.4.1.6.c both put the name of the
# ordering clinician on the LABORATORY's report. It is not enough that the HIS
# knows who ordered a test: the laboratory must know too, because the laboratory
# is who telephones a critical value and whose report is the record of the
# examination. Until this suite existed, every order in OpenELIS was attributed
# to "OpenELIS Laboratory" — the integration's own routing identity.
#
# WHY IT WAS BROKEN, AND WHY THE FIX IS CONFIGURATION AND NOT A PATCH
# LabOrderSearchProvider looks for the requester in two places, in order:
#
#   1. task.owner              — but only if the reference contains
#                                "Practitioner"
#   2. serviceRequest.requester — only reached when 1 found nothing
#
# task.owner is the laboratory's ROUTING ADDRESS: OpenELIS polls
# Task?status=requested&owner={identifier} and that is how an order finds its
# laboratory at all. Typed as a Practitioner it also, silently, becomes the
# answer to "who ordered this?" — so step 2 never ran and the real doctor was
# unreachable. Typing the owner as an Organization fails the string test in step
# 1, which lets step 2 run. Upstream code, unmodified, working as written.
#
# WHAT THIS COSTS, AND WHY THE FIRST SECTION IS THE MOST IMPORTANT ONE
# task.owner is the routing key. Getting it wrong does not degrade a field — no
# order reaches the laboratory at all. Section 1 is therefore not a formality:
# it is the check that says the integration is still alive, and it runs first so
# that a failure here is not mistaken for a problem with the clinician.
#
# REPEATABILITY
# Each run invents fresh usr_ids. That is not tidiness — OpenELIS copies a
# Practitioner into its own records the first time it sees one and never
# refreshes it (proved in section 5), so a fixed id would make a second run
# assert against the FIRST run's names.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATIENT="11111111-1111-1111-1111-111111111111"
TEST_CODE=$(any_active_test_code)

# Distinct per run. See REPEATABILITY above.
BASE_ID=$(( 70000 + RANDOM % 20000 ))

# ---------------------------------------------------------------------------
# The provider id for a given usr_id, mirroring mint-token.sh's stand-in for the
# lookup a real deployment does against mlh_his_hcp_health_care_provider.
#
# Deliberately never equal to the usr_id. The account and the clinician are
# different things — that is the whole of db/his/015 — and a fixture where both
# read the same number could not tell the two apart, so it would pass whichever
# one the bridge sent.
hcp_of() { echo $(( 9000 + $1 )); }

# Places an order as a named clinician and echoes the order number.
#
# A separate token per clinician, because ordering_provider is written from the
# token's usr_full_name and never from the request body (db/his/008) — which is
# the whole point, and means the only way to order as someone else is to be
# them. Distinct usr_ids, because the estate keeps ONE session per user and
# re-minting for the same id would revoke the token the previous step is using.
order_as() {   # order_as <usr_id> <full name> [extra json fields]
    local uid="$1" name="$2" extra="${3:-}"
    local token number
    token=$("$ROOT/scripts/mint-token.sh" --quiet --user "$uid" \
        --name "clinician.$uid" --full-name "$name" \
        ${LAB_ORDER_GROUP:+--groups "$LAB_ORDER_GROUP"} 2>/dev/null)
    number=$(curl -sf -H "Authorization: Bearer $token" -X POST "${API}/lab-orders" \
        -H 'Content-Type: application/json' \
        -d "{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",\"facilityCode\":\"FAC-001\"${extra}}" \
        | json_field "['orderNumber']")

    # An inpatient order is HELD and publishes nothing until the ward records
    # the draw, so waiting for a Task here would time out on every call.
    [[ "$extra" == *INPATIENT* ]] || await_publish "$number"
    echo "$number"
}

# The POST returns as soon as the order is committed; the bridge picks it up
# from the outbox through Kafka afterwards. Asserting on the published FHIR
# straight after ordering therefore reads an empty table and reports a mapping
# bug that is really a race — which is exactly what this suite did on its first
# run, failing nine checks that were all correct.
await_publish() {   # await_publish <orderNumber> [tries]
    local n="$1" tries="${2:-30}"
    for _ in $(seq 1 "$tries"); do
        [[ -n "$(bridge_sql "SELECT resource_id FROM bridge.fhir_resources
                              WHERE resource_type = 'ServiceRequest'
                                AND resource_id = '$n'")" ]] && return 0
        sleep 1
    done
    return 1
}

# What the laboratory's accessioning screen is handed for an order.
#
# The real endpoint the wizard's own JavaScript calls (ajaxCalls.js:77), reached
# on the webapp's port rather than through the proxy — the proxy serves the React
# app for unmatched paths, so a wrong URL here returns an HTML page and every
# assertion fails for a reason that has nothing to do with the integration.
wizard_xml() {   # wizard_xml <orderNumber>
    local base="https://localhost:${OE_HTTPS_PORT:-8443}/OpenELIS-Global"
    local jar csrf token
    jar=$(mktemp)
    csrf=$(curl -sk -c "$jar" "$base/LoginPage" \
        | grep -o 'name="_csrf"[^>]*value="[^"]*"' | sed 's/.*value="//;s/"$//' | head -1)
    curl -sk -b "$jar" -c "$jar" -X POST "$base/ValidateLogin" \
        --data-urlencode "loginName=admin" \
        --data-urlencode "password=$OE_DEFAULT_PASSWORD" \
        --data-urlencode "_csrf=$csrf" -o /dev/null
    token=$(curl -sk -b "$jar" -c "$jar" "$base/session" | sed 's/.*"csrf":"//;s/".*//')
    curl -sk -b "$jar" -H "X-CSRF-Token: $token" \
        "$base/ajaxQueryXML?provider=LabOrderSearchProvider&orderNumber=$1"
    rm -f "$jar"
}

# The Practitioner reference the bridge put on an order's ServiceRequest.
requester_of() {   # requester_of <orderNumber>
    bridge_sql "SELECT r.content -> 'requester' ->> 'reference'
                  FROM bridge.fhir_resources r
                 WHERE r.resource_type = 'ServiceRequest' AND r.resource_id = '$1'"
}

await_import() {   # await_import <orderNumber> [tries]
    local n="$1" tries="${2:-24}"
    for _ in $(seq 1 "$tries"); do
        [[ -n "$(oe_sql "SELECT status_id FROM electronic_order WHERE external_id='$n'")" ]] && return 0
        sleep 10
    done
    return 1
}

info "test $TEST_CODE, clinician ids from $BASE_ID"

# ---------------------------------------------------------------------------
section "1 · The laboratory's address is a place, not a person"

# The routing key. Everything else in this suite is downstream of it, and a
# failure here means no order reaches the laboratory at all.
check "OpenELIS is configured to poll for an Organization owner" \
    "[[ '$OE_REMOTE_SOURCE_IDENTIFIER' == Organization/* ]]"

# The single most common way to break the sandbox is for these two to drift.
# render-config.sh proves it at render time; this proves the RUNNING webapp
# agrees, which is a different claim — the property is mounted as a file and a
# container started before the last `make config` still serves the old value.
check "The running webapp polls for exactly what the bridge stamps" \
    "docker exec openelis-webapp grep -qx \
        'org.openelisglobal.remote.source.identifier=$OE_REMOTE_SOURCE_IDENTIFIER' \
        /run/secrets/common.properties"

LIVE=$(order_as "$BASE_ID" "Amadou Konate")
if [[ -z "$LIVE" ]]; then
    bad "An order can still be placed" "no order number returned"
    summary; exit 1
fi
ok "An order was placed ($LIVE)"

LIVE_OWNER=$(bridge_sql "SELECT content -> 'owner' ->> 'reference'
                           FROM bridge.fhir_resources
                          WHERE resource_type = 'Task'
                            AND content -> 'identifier' -> 0 ->> 'value' = '$LIVE'")
check "The bridge published it under an Organization owner" \
    "[[ '$LIVE_OWNER' == '$OE_REMOTE_SOURCE_IDENTIFIER' ]]"

# A laboratory is normally a department inside a hospital, so the owner is named
# after the hospital and that name is per-deployment. Asserting it is configured
# rather than hardcoded is what stops a product name from appearing where a
# hospital's name belongs.
#
# Only OUR copy is checked. The authoritative name is the one on the same row in
# OpenELIS's `organization` table, which the laboratory owns and maintains —
# asserting on that would be this sandbox claiming authority over the
# laboratory's own records.
LIVE_LAB_NAME=$(bridge_rows "SELECT content ->> 'name'
                               FROM bridge.fhir_resources
                              WHERE resource_type = 'Organization'
                                AND resource_id = '${OE_REMOTE_SOURCE_IDENTIFIER#Organization/}'" | xargs)
check "The laboratory is published under its configured name, not a hardcoded one" \
    "[[ '$LIVE_LAB_NAME' == '$OE_LAB_NAME' ]]"

# The regression that matters, scoped to the Tasks it can matter for.
#
# Only `requested` Tasks are still polled for; an accepted or rejected one has
# been delivered and keeps whatever owner it was written with, which is the
# honest record of how it was sent. A REQUESTED Task under the old owner is a
# different thing entirely — an order the laboratory will never be offered
# again, because the poll no longer asks for that address. That is the failure
# mode of changing this value, and it is silent.
STRANDED=$(bridge_sql "SELECT count(*) FROM bridge.fhir_resources
                        WHERE resource_type = 'Task'
                          AND content ->> 'status' = 'requested'
                          AND content -> 'owner' ->> 'reference'
                              IS DISTINCT FROM '$OE_REMOTE_SOURCE_IDENTIFIER'")
check "No undelivered order is stranded under a different owner" \
    "[[ '$STRANDED' == 0 ]]"

info "waiting for OpenELIS to poll and import…"
if await_import "$LIVE"; then
    ok "OpenELIS found and imported it — the poll still works"
else
    bad "OpenELIS found and imported it" \
        "no electronic_order row for $LIVE. The Organization owner may not be routable."
    summary; exit 1
fi

# ---------------------------------------------------------------------------
section "2 · The clinician travels with the order"

LIVE_REQ=$(requester_of "$LIVE")

check "ServiceRequest.requester names a Practitioner" \
    "[[ '$LIVE_REQ' == Practitioner/* ]]"

# LabOrderSearchProvider.addRequester calls UUID.fromString() on this id with no
# guard. A raw provider id like '$(hcp_of "$BASE_ID")' would throw inside the wizard
# — a 500 on the laboratory's screen, not a blank field.
check "The Practitioner id is a UUID, which the wizard requires" \
    "[[ '${LIVE_REQ#Practitioner/}' =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]"

LIVE_USR=$(bridge_sql "SELECT content -> 'identifier' -> 0 ->> 'value'
                         FROM bridge.fhir_resources
                        WHERE resource_type = 'Practitioner'
                          AND resource_id = '${LIVE_REQ#Practitioner/}'")
# The CLINICAL identity, not the account. LIVE_USR reading back as $BASE_ID
# would mean the bridge had gone back to keying on the login, which is the
# regression db/his/015 exists to prevent.
check "The Practitioner carries the clinician's own id, not the account's" \
    "[[ '$LIVE_USR' == '$(hcp_of "$BASE_ID")' && '$LIVE_USR' != '$BASE_ID' ]]"

LIVE_LICENCE=$(bridge_sql "SELECT content -> 'identifier' -> 1 ->> 'value'
                             FROM bridge.fhir_resources
                            WHERE resource_type = 'Practitioner'
                              AND resource_id = '${LIVE_REQ#Practitioner/}'")
# What a human in the laboratory reconciles on. hcp_id means nothing outside the
# HIS; a licence number is what a technician and a regulator both recognise.
check "…and their licence number as a second identifier" \
    "[[ '$LIVE_LICENCE' == 'ML-$(hcp_of "$BASE_ID")' ]]"

LIVE_NAME=$(bridge_rows "SELECT (content -> 'name' -> 0 ->> 'family') || '|' ||
                                (content -> 'name' -> 0 -> 'given' ->> 0)
                           FROM bridge.fhir_resources
                          WHERE resource_type = 'Practitioner'
                            AND resource_id = '${LIVE_REQ#Practitioner/}'" | xargs)
check "The display name is split into given and family, which OpenELIS reads separately" \
    "[[ '$LIVE_NAME' == 'Konate|Amadou' ]]"

LIVE_IN_OE=$(oe_sql "SELECT count(*) FROM clinlims.hfj_resource
                      WHERE fhir_id = '${LIVE_REQ#Practitioner/}'")
check "OpenELIS copied the Practitioner into its own records" \
    "[[ '$LIVE_IN_OE' == 1 ]]"

# ---------------------------------------------------------------------------
section "3 · The laboratory's accessioning screen names the doctor"

# The point of the whole change. Everything above is machinery; this is the
# field a technician actually looks at.
WIZ=$(wizard_xml "$LIVE")

check_contains "The wizard answers for this order" "echo '$WIZ'" "<message>valid</message>"

check_contains "It names the ordering clinician" "echo '$WIZ'" \
    "<requester><firstName>Amadou</firstName><lastName>Konate</lastName></requester>"

# The defect this change closes, asserted directly: before it, EVERY order was
# attributed to the integration's own routing identity.
check "It is no longer attributed to the laboratory itself" \
    "[[ '$WIZ' != *'<lastName>Laboratory</lastName>'* ]]"

# ---------------------------------------------------------------------------
section "4 · One clinician stays one clinician"

# db/his/008 made the HIS key orders on usr_id rather than on a typed name,
# because 'Dr Konate', 'Dr Konaté' and 'dr konate' were becoming three
# clinicians. Deriving the FHIR identity from the name here would reopen exactly
# that defect one layer further out, so it is worth proving it did not.
SAME_1=$(order_as "$((BASE_ID + 1))" "Fatou Diallo")
SAME_2=$(order_as "$((BASE_ID + 1))" "Fatou Diallo")
OTHER=$(order_as "$((BASE_ID + 2))" "Fatou Diallo")

REQ_SAME_1=$(requester_of "$SAME_1")
REQ_SAME_2=$(requester_of "$SAME_2")
REQ_OTHER=$(requester_of "$OTHER")

check "Two orders from one clinician reference one Practitioner" \
    "[[ -n '$REQ_SAME_1' && '$REQ_SAME_1' == '$REQ_SAME_2' ]]"

check "Two clinicians who share a name are still two Practitioners" \
    "[[ -n '$REQ_OTHER' && '$REQ_SAME_1' != '$REQ_OTHER' ]]"

# The identity survives the spelling, which is the property db/his/008 bought.
SPELLED=$(order_as "$((BASE_ID + 1))" "Fatou Diallo-Sow")
REQ_SPELLED=$(requester_of "$SPELLED")
check "A clinician who changes how their name is written is still the same clinician" \
    "[[ -n '$REQ_SPELLED' && '$REQ_SPELLED' == '$REQ_SAME_1' ]]"

# ---------------------------------------------------------------------------
section "5 · What the laboratory does NOT do with the name"

# UPSTREAM BEHAVIOUR, asserted so it is a known fact rather than a surprise in
# production. FhirApiWorkFlowServiceImpl.getProviderWithSameIdentifier finds the
# Practitioner it already holds and reuses it AS IT IS — the incoming name is
# discarded, and no second version is ever written. A clinician's name is
# therefore frozen at the moment the laboratory first imported them, and a
# later correction in the HIS never reaches the laboratory's report.
#
# This is the right trade and not a reason to key on the name instead: a
# name-derived identity would make every spelling a new clinician, which is
# worse and is the defect db/his/008 closed. The correct fix is upstream.
#
# The assertion is on the VERSION COUNT and not on which name survived. Both
# spellings can arrive in one poll, and OpenELIS imports a batch in an order of
# its own choosing — so "the first name you sent" is not a thing the laboratory
# can be held to. What is invariant is that it wrote the Practitioner once and
# never again, having been shown two different names for it.
info "waiting for both spellings to import…"
await_import "$SAME_1" 12
await_import "$SPELLED" 12

SPELLED_UUID=${REQ_SPELLED#Practitioner/}

SENT_NAME=$(bridge_rows "SELECT content -> 'name' -> 0 ->> 'family'
                           FROM bridge.fhir_resources
                          WHERE resource_type = 'Practitioner'
                            AND resource_id = '$SPELLED_UUID'" | xargs)
check "The bridge sent the corrected spelling" \
    "[[ '$SENT_NAME' == 'Diallo-Sow' ]]"

VERSIONS=$(oe_sql "SELECT count(*) FROM clinlims.hfj_res_ver v
                     JOIN clinlims.hfj_resource r ON r.res_id = v.res_id
                    WHERE r.fhir_id = '$SPELLED_UUID'")
check "KNOWN: shown two names for one clinician, OpenELIS stored one and never updated it" \
    "[[ '$VERSIONS' == 1 ]]"

# Frozen, but not corrupted: whichever of the two it kept is a name we actually
# sent. This is what separates "does not refresh" from "mangles".
HELD_NAME=$(oe_rows "SELECT v.res_text_vc FROM clinlims.hfj_res_ver v
                       JOIN clinlims.hfj_resource r ON r.res_id = v.res_id
                      WHERE r.fhir_id = '$SPELLED_UUID'
                      ORDER BY v.res_ver DESC LIMIT 1" \
    | python3 -c "import json,sys; print(json.loads(sys.stdin.read() or '{}').get('name',[{}])[0].get('family',''))" 2>/dev/null)
check "The name it kept is one the HIS actually sent" \
    "[[ '$HELD_NAME' == 'Diallo' || '$HELD_NAME' == 'Diallo-Sow' ]]"

# ---------------------------------------------------------------------------
section "6 · A signed-in user who is not a clinician"

# A receptionist, a ward clerk, a records officer: an ACCOUNT with no provider
# row. mlh_his_hcp_health_care_provider.usr_id is nullable in both directions —
# a provider may have no login, and a login may have no provider — so this is an
# ordinary state of the real system, not a corrupted fixture.
#
# It is also how orders predating db/his/015 behave, since they carry no
# clinical identity either. One case, both situations.
#
# What must happen: the order still reaches the laboratory, because a missing
# name is a gap in the record and not a reason to withhold a test from a
# patient; and no clinician is invented for it — least of all the account, which
# would put a login on a laboratory report as though it were a person.
#
# Placed through the inpatient path so the dispatch is a separate, observable
# step rather than a race with the assertions.
CLERK_ID=$(( BASE_ID + 3 ))
CLERK_TOKEN=$("$ROOT/scripts/mint-token.sh" --quiet --user "$CLERK_ID" \
    --name "front.desk.$CLERK_ID" --full-name "Fatima Reception" --no-provider \
    ${LAB_ORDER_GROUP:+--groups "$LAB_ORDER_GROUP"} 2>/dev/null)

CLERK_ORDER=$(curl -sf -H "Authorization: Bearer $CLERK_TOKEN" -X POST "${API}/lab-orders" \
    -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",
         \"facilityCode\":\"FAC-001\",\"patientClass\":\"INPATIENT\"}" \
    | json_field "['orderNumber']")

if [[ -n "$CLERK_ORDER" ]]; then
    ok "A non-clinician can still place an order ($CLERK_ORDER)"
else
    bad "A non-clinician can still place an order" "no order number returned"
fi

# The account IS recorded — the audit trail must always answer "who did this",
# and it is the laboratory's records that must not name them as the clinician.
check "The account is recorded in the HIS for the audit trail" \
    "[[ \$(his_sql \"SELECT ordering_provider_id FROM his.lab_orders
                      WHERE order_number='$CLERK_ORDER'\") == '$CLERK_ID' ]]"

check "…but no clinical identity was recorded, because there is none" \
    "[[ -z \$(his_sql \"SELECT coalesce(ordering_provider_hcp_id,'')
                         FROM his.lab_orders WHERE order_number='$CLERK_ORDER'\") ]]"

curl -sf -H "Authorization: Bearer $CLERK_TOKEN" -X POST \
    "${API}/lab-orders/${CLERK_ORDER}/collection" -H 'Content-Type: application/json' \
    -d "{\"collectedAt\":\"$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')\"}" -o /dev/null

LEGACY="$CLERK_ORDER"

# Waiting first is not optional here. "No requester was published" and "nothing
# has been published yet" look identical, so without this the check passes for
# the wrong reason and would keep passing if the mapper started inventing one.
if await_publish "$LEGACY"; then
    ok "The ward's draw dispatched the held order"
else
    bad "The ward's draw dispatched the held order" "nothing published for $LEGACY"
fi

check "The bridge published it with no requester rather than inventing one" \
    "[[ -z '$(requester_of "$LEGACY")' ]]"

info "waiting for the unattributed order to import…"
if await_import "$LEGACY" 18; then
    ok "It still reached the laboratory — a missing name withholds no test"
else
    bad "It still reached the laboratory" "no electronic_order row for $LEGACY"
fi

# The unguarded UUID.fromString in addRequester's else branch reads task.owner
# when there is no requester. That is an Organization uuid now, which parses —
# but it is one character away from a 500 on the technician's screen, so assert
# the screen actually renders.
LEGACY_WIZ=$(wizard_xml "$LEGACY")
check_contains "The wizard still renders, with the requester simply empty" \
    "echo '$LEGACY_WIZ'" "<message>valid</message>"

# The clerk's own name must not appear as the ordering clinician. They placed
# the order and are named in the HIS audit trail for it; they are not who the
# laboratory telephones about a critical value, and a laboratory record saying
# otherwise would be a false clinical attribution.
check "The account holder was not passed off as the clinician" \
    "[[ '$LEGACY_WIZ' != *'<lastName>Reception'* ]]"

# ---------------------------------------------------------------------------
section "7 · Names a real HIS will actually hold"

# One token, one name each. These assert the MAPPING, not the import, so they
# read the bridge's own store and do not wait on a poll.
#
# Echoes "family|given" so one query answers both halves of every case — and so
# a name that lands entirely in the wrong field fails loudly rather than half
# passing.
name_parts() {   # name_parts <orderNumber>
    local uuid
    uuid=$(requester_of "$1")
    uuid=${uuid#Practitioner/}
    [[ -z "$uuid" ]] && { echo "NO-REQUESTER"; return; }
    bridge_rows "SELECT (content -> 'name' -> 0 ->> 'family') || '|' ||
                        coalesce(content -> 'name' -> 0 -> 'given' ->> 0, '')
                   FROM bridge.fhir_resources
                  WHERE resource_type = 'Practitioner'
                    AND resource_id = '$uuid'" | xargs
}

# Mononyms are ordinary in much of the world. OpenELIS reads getFamily() and
# shows it, so a single token has to land there and not in given — a mononym
# filed as a given name shows the laboratory a blank where the doctor should be.
ONE=$(name_parts "$(order_as "$((BASE_ID + 4))" "Konate")")
check "A single-name clinician becomes the family name, which is the field shown" \
    "[[ '$ONE' == 'Konate|' ]]"

# Titles and compound names: last token is the family, the rest is given.
THREE=$(name_parts "$(order_as "$((BASE_ID + 5))" "Dr Marie Claire Sow")")
check "A compound name keeps every part, with the last token as the family name" \
    "[[ '$THREE' == 'Sow|Dr Marie Claire' ]]"

# The laboratory's own lastNameCharset includes the accented Latin range, so
# these are valid clinician names, not exotica. Mangling them here would put a
# misspelled name on a clinical report.
ACCENT=$(name_parts "$(order_as "$((BASE_ID + 6))" "Aminata Konaté")")
check "Accented names survive the crossing unchanged" \
    "[[ '$ACCENT' == 'Konaté|Aminata' ]]"

# NOT sanitised, deliberately. OpenELIS validates provider names against
# lastNameCharset — letters, space, apostrophe, dot and hyphen, NO DIGITS — and
# refuses one containing a digit when the accessioner saves. Stripping the digit
# here to slip past that would alter a clinician's identity in a clinical record
# to avoid an error message. The laboratory refusing a malformed name is the
# correct outcome; the fix belongs in the HIS that holds it.
DIGITS=$(name_parts "$(order_as "$((BASE_ID + 7))" "Ward 3 Locum")")
check "A name the laboratory will refuse is passed through, not quietly rewritten" \
    "[[ '$DIGITS' == 'Locum|Ward 3' ]]"

# ---------------------------------------------------------------------------
section "8 · The clinician survives a handoff to someone else"

# THE ONLY SECTION HERE GUARDING A BUG THIS SANDBOX CANNOT OTHERWISE PRODUCE.
#
# An outpatient order is placed and dispatched in one request, so the doctor is
# still the signed-in user when it goes. A real HIS has a workflow in between —
# insurance verification, fulfilment, approval — and publishes once at the end.
# The clinical decision and the dispatch become different moments, by different
# people, minutes or days apart.
#
# That gap has one failure in it, and it is a single plausible line in whichever
# service finally publishes:
#
#     ordering_provider_hcp_id: req.user.hcp_id   // whoever advanced the workflow
#
# It passes every same-session test. For an insured patient the approval clears
# in a minute, often without the doctor leaving the screen, so "who is signed in"
# and "who ordered this" are the same person and both answers look right. It
# breaks only when they differ — the delayed, insurance-held, supervisor
# re-created order, which is also the one least likely to be inspected and the
# one where the laboratory most needs a real doctor to telephone.
#
# We do not model insurance to test it. The INPATIENT path already has the
# shape: the doctor places an order that publishes nothing, and a DIFFERENT
# person — the nurse at the bedside — is what causes it to dispatch. Same two
# actors, same two moments, a different reason for the wait.
#
# The rule this asserts: once the order row exists, the clinician is read FROM
# THE ROW, never from the session of whoever advances it.

DOC_ID=$(( BASE_ID + 8 ))
NURSE_ID=$(( BASE_ID + 9 ))

# Placed by the doctor, and held — nothing has reached the laboratory yet.
HANDOFF=$(order_as "$DOC_ID" "Ibrahim Toure" ',"patientClass":"INPATIENT"')

check "The doctor's order is held, with nothing published yet" \
    "[[ -z '$(requester_of "$HANDOFF")' ]]"

# A different person entirely, with their own clinical identity. If the dispatch
# ever reads the session instead of the row, THIS is who the laboratory is told
# ordered the test.
NURSE_TOKEN=$("$ROOT/scripts/mint-token.sh" --quiet --user "$NURSE_ID" \
    --name "nurse.$NURSE_ID" --full-name "Mariam Cisse" \
    ${LAB_ORDER_GROUP:+--groups "$LAB_ORDER_GROUP"} 2>/dev/null)

curl -sf -H "Authorization: Bearer $NURSE_TOKEN" -X POST \
    "${API}/lab-orders/${HANDOFF}/collection" -H 'Content-Type: application/json' \
    -d "{\"collectedAt\":\"$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')\"}" -o /dev/null

if await_publish "$HANDOFF"; then
    ok "The nurse's action dispatched it — a second person, a second moment"
else
    bad "The nurse's action dispatched it" "nothing published for $HANDOFF"
fi

HANDOFF_REQ=$(requester_of "$HANDOFF")
HANDOFF_HCP=$(bridge_sql "SELECT content -> 'identifier' -> 0 ->> 'value'
                            FROM bridge.fhir_resources
                           WHERE resource_type = 'Practitioner'
                             AND resource_id = '${HANDOFF_REQ#Practitioner/}'")
HANDOFF_NAME=$(bridge_rows "SELECT content -> 'name' -> 0 ->> 'family'
                              FROM bridge.fhir_resources
                             WHERE resource_type = 'Practitioner'
                               AND resource_id = '${HANDOFF_REQ#Practitioner/}'" | xargs)

# The assertion the whole section exists for.
check "The laboratory is told the DOCTOR who ordered it…" \
    "[[ '$HANDOFF_HCP' == '$(hcp_of "$DOC_ID")' && '$HANDOFF_NAME' == 'Toure' ]]"

# Stated separately from the one above so a failure names the actual mistake:
# "the dispatcher was published as the clinician" is a different diagnosis from
# "the wrong doctor was published", and they have different fixes.
#
# The -n guard is not decoration. Mutation-testing this section — deliberately
# writing the bug it exists to catch — showed this check passing while the
# section as a whole was broken: with no requester published at all, "not the
# nurse" is vacuously true. A check that cannot fail when the thing it guards is
# broken is worse than no check, because it reports safety.
check "…and NOT the nurse who dispatched it" \
    "[[ -n '$HANDOFF_HCP' \
        && '$HANDOFF_HCP' != '$(hcp_of "$NURSE_ID")' && '$HANDOFF_NAME' != 'Cisse' ]]"

# The nurse is not erased — she observed the draw, and that is hers to have
# stated. Attribution and action are different records: the order says who
# decided, the trail says who did what and when.
check "The nurse's action is in the audit trail, where an action belongs" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_order_events e
                      JOIN his.lab_orders o USING (order_id)
                     WHERE o.order_number='$HANDOFF'
                       AND e.event_type='SPECIMEN_COLLECTED'\") -ge 1 ]]"

summary
