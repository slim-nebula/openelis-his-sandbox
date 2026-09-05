#!/usr/bin/env bash
# =============================================================================
# Specimen collection time — the two workflows
#
# A result released five minutes ago may be from blood drawn six hours ago. The
# results table showed only the release time, so a clinician had no way to judge
# whether the value still described the patient. ISO 15189:2022 7.4.1.7.a
# requires the collection time when it matters for care, and this is the case it
# matters for.
#
# A collection time is a fact about a physical event, and only whoever watched
# it can state it. That splits the work in two:
#
#   OUTPATIENT  the patient walks to the laboratory and a technician draws
#               there. The LABORATORY observed it, and reports it back on
#               Specimen.collection.collected. We read it; we never send one.
#
#   INPATIENT   a nurse draws at the bedside and nobody in the laboratory sees
#               it. The order is HELD at AWAITING_COLLECTION with no outbox row,
#               so the laboratory hears nothing until the ward records the draw
#               — at which point the collection time and the dispatch commit
#               together and travel out on Specimen.collection.collectedDateTime.
#
# Why the hold, rather than sending now and topping up later: once OpenELIS
# imports a Task it moves the status off `requested` and never polls it again,
# so a follow-up would not be read. Holding is also the honest thing to do —
# until the tube exists there is nothing for the laboratory to act on.
#
# What this suite does NOT cover: the outpatient read-back end to end. That
# needs a lab user to accession a real sample and type a collection date, which
# is the manual step in make e2e. The projection of a laboratory-reported
# collection time is exercised here through the same FHIR push the laboratory
# uses, which is what make results does for values.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATIENT="11111111-1111-1111-1111-111111111111"
TEST_CODE=$(any_active_test_code)

info "test $TEST_CODE"

# ---------------------------------------------------------------------------
section "1 · An outpatient order dispatches immediately"

OUT_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",
         \"facilityCode\":\"FAC-001\",\"patientClass\":\"OUTPATIENT\"}")
OUT_NUMBER=$(echo "$OUT_JSON" | json_field "['orderNumber']")
OUT_ID=$(echo "$OUT_JSON" | json_field "['orderId']")

if [[ -z "$OUT_NUMBER" ]]; then
    bad "Outpatient order created" "no order number returned"
    summary; exit 1
fi
ok "Outpatient order created ($OUT_NUMBER)"

# Asserted as "not held", not as "== CREATED".
#
# CREATED is the status an outpatient order is BORN with, and it does not stay
# there: the relay picks the order up, the bridge publishes it, and
# lab.order.sent moves it to SENT_TO_LIS — sometimes before this line runs. That
# made this check fail intermittently while nothing was wrong, which is worse
# than useless, because a suite that cries wolf gets ignored on the day it is
# right.
#
# The property being tested is the fork in §2: an outpatient order is NOT parked
# waiting for a ward to draw the specimen. Any status other than
# AWAITING_COLLECTION satisfies that, and progressing past CREATED is the
# integration working rather than a defect.
OUT_STATUS=$(his_sql "SELECT order_status FROM his.lab_orders WHERE order_number='$OUT_NUMBER'")
check "It is not held for a bedside draw (status $OUT_STATUS)" \
    "[[ -n '$OUT_STATUS' && '$OUT_STATUS' != AWAITING_COLLECTION ]]"

# The outbox row IS the dispatch. Its presence is what separates the two
# workflows, so assert on it rather than on a status alone.
check "An outbox row was written, so the laboratory will hear about it" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.outbox WHERE aggregate_id='$OUT_ID'\") -ge 1 ]]"

check "No ward collection time — the laboratory observes that draw" \
    "[[ \$(his_sql \"SELECT coalesce(collected_at::text,'NONE') FROM his.lab_orders WHERE order_number='$OUT_NUMBER'\") == NONE ]]"

# ---------------------------------------------------------------------------
section "2 · An inpatient order waits for the ward"

IN_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",
         \"facilityCode\":\"FAC-001\",\"patientClass\":\"INPATIENT\"}")
IN_NUMBER=$(echo "$IN_JSON" | json_field "['orderNumber']")
IN_ID=$(echo "$IN_JSON" | json_field "['orderId']")

if [[ -z "$IN_NUMBER" ]]; then
    bad "Inpatient order created" "no order number returned"
    summary; exit 1
fi
ok "Inpatient order created ($IN_NUMBER)"

check "It is held at AWAITING_COLLECTION" \
    "[[ \$(his_sql \"SELECT order_status FROM his.lab_orders WHERE order_number='$IN_NUMBER'\") == AWAITING_COLLECTION ]]"

# The whole point of the hold. If this row existed the laboratory would be
# expecting a specimen that nobody has drawn.
check "NOTHING was queued for the laboratory" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.outbox WHERE aggregate_id='$IN_ID'\") == 0 ]]"

check "And nothing reached the bridge" \
    "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.order_tracking WHERE order_number='$IN_NUMBER'\") == 0 ]]"

# ---------------------------------------------------------------------------
section "3 · Recording the draw releases it"

DRAWN_AT=$(date -u -v-90M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

DRAW_JSON=$(api_curl -sf -X POST "${API}/lab-orders/${IN_NUMBER}/collection" \
    -H 'Content-Type: application/json' -d "{\"collectedAt\":\"$DRAWN_AT\"}")

check_contains "The draw is recorded against the order" \
    "echo '$DRAW_JSON'" '"orderStatus":"CREATED"'

check "The ward collection time is stored" \
    "[[ -n \$(his_sql \"SELECT collected_at FROM his.lab_orders WHERE order_number='$IN_NUMBER'\") ]]"

# The collection time and the dispatch commit together. Either alone is a
# failure that retrying cannot fix: a time with no dispatch strands the order
# with a nurse believing it is done; a dispatch with no time loses the only
# reason the order was waiting.
check "The dispatch was queued in the SAME act" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.outbox WHERE aggregate_id='$IN_ID'\") -ge 1 ]]"

check "An audit row records the collection" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.lab_order_events WHERE order_id='$IN_ID' AND event_type='SPECIMEN_COLLECTED'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "4 · The collection time reaches OpenELIS on the wire"

TRACKED=""
for _ in $(seq 1 25); do
    [[ -n $(bridge_sql "SELECT fhir_specimen_id FROM bridge.order_tracking WHERE order_number='$IN_NUMBER'" 2>/dev/null) ]] \
        && { TRACKED=yes; break; }
    sleep 2
done

if [[ -z "$TRACKED" ]]; then
    bad "The released order reached the bridge" "no tracking row after 50s"
else
    ok "The released order reached the bridge"

    # Read what was actually PUBLISHED, not what we intended to publish. This is
    # the assertion that would have caught the specimen-coding defect earlier.
    SENT=$(bridge_rows "SELECT content->'collection'->>'collectedDateTime'
                          FROM bridge.fhir_resources
                         WHERE resource_type='Specimen'
                           AND resource_id = (SELECT fhir_specimen_id FROM bridge.order_tracking
                                               WHERE order_number='$IN_NUMBER')")

    [[ -n "$SENT" && "$SENT" != "null" ]] \
        && ok "Specimen.collection.collectedDateTime is on the wire ($SENT)" \
        || bad "Specimen.collection.collectedDateTime is on the wire" "got '${SENT:-empty}'"

    # It used to carry order.CreatedAt, telling the laboratory it had received a
    # specimen at the moment the doctor clicked "order" — before anyone drew
    # blood. Receipt is the laboratory's own event to observe.
    RECEIVED=$(bridge_rows "SELECT content->>'receivedTime'
                              FROM bridge.fhir_resources
                             WHERE resource_type='Specimen'
                               AND resource_id = (SELECT fhir_specimen_id FROM bridge.order_tracking
                                                   WHERE order_number='$IN_NUMBER')")

    [[ -z "$RECEIVED" || "$RECEIVED" == "null" ]] \
        && ok "We no longer claim the laboratory received the specimen" \
        || bad "We no longer claim the laboratory received the specimen" "receivedTime = '$RECEIVED'"
fi

# ---------------------------------------------------------------------------
section "5 · Refusals"

# An outpatient draw is observed by the laboratory. Accepting a ward time for
# one would create a second version of a single fact, with no way to tell which
# is the observation.
check "A ward draw cannot be recorded against an outpatient order" \
    "[[ \$(api_curl -s -o /dev/null -w '%{http_code}' -X POST '${API}/lab-orders/${OUT_NUMBER}/collection' \
        -H 'Content-Type: application/json' -d '{\"collectedAt\":\"$DRAWN_AT\"}') == 400 ]]"

check "Recording the same draw twice is refused, not silently re-sent" \
    "[[ \$(api_curl -s -o /dev/null -w '%{http_code}' -X POST '${API}/lab-orders/${IN_NUMBER}/collection' \
        -H 'Content-Type: application/json' -d '{\"collectedAt\":\"$DRAWN_AT\"}') == 400 ]]"

# A draw is a thing that has happened. A future timestamp is a typo or a clock
# problem, and it would make the specimen look fresher than it is.
FUTURE=$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours' +%Y-%m-%dT%H:%M:%SZ)
FUT_JSON=$(api_curl -sf -X POST "${API}/lab-orders" -H 'Content-Type: application/json' \
    -d "{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",
         \"facilityCode\":\"FAC-001\",\"patientClass\":\"INPATIENT\"}")
FUT_NUMBER=$(echo "$FUT_JSON" | json_field "['orderNumber']")

check "A collection time in the future is refused" \
    "[[ \$(api_curl -s -o /dev/null -w '%{http_code}' -X POST '${API}/lab-orders/${FUT_NUMBER}/collection' \
        -H 'Content-Type: application/json' -d '{\"collectedAt\":\"$FUTURE\"}') == 400 ]]"

check "An unknown patient class is refused rather than defaulted" \
    "[[ \$(api_curl -s -o /dev/null -w '%{http_code}' -X POST '${API}/lab-orders' \
        -H 'Content-Type: application/json' \
        -d '{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",\"facilityCode\":\"FAC-001\",\"patientClass\":\"DAYCASE\"}') == 400 ]]"

# ---------------------------------------------------------------------------
section "6 · An order with no collection time says so"

# The display state that matters most. A blank cannot be told apart from a
# rendering fault, and substituting a received or released time would look
# exactly like an observed collection time and be believed.
RESULTS=$(api_curl -sf "${API}/patients/${PATIENT}/results")

check_contains "The API exposes collectedAt, present or null" \
    "echo '$RESULTS'" 'collectedAt'

check_contains "…and says which system observed the draw" \
    "echo '$RESULTS'" 'collectionSource'


# ---------------------------------------------------------------------------
section "7 · Where the order came from"

# facility_code used to be free text with a default nobody changed, and it
# reached nothing — verified on the wire, FAC-001 appeared in none of the five
# resources we publish. It is acquiring a consumer: the accessioning wizard
# REQUIRES a Referring Site, and a technician types it on every order because we
# send nothing.
check_contains "The site register lists facilities with a type" \
    "api_curl -sf ${API}/facilities" 'facilityType'

# The type is the part a laboratory acts on: a ward, a clinic and an emergency
# department are different origins with different turnaround expectations.
check_contains "…including a ward, which is a different origin from a clinic" \
    "api_curl -sf ${API}/facilities" 'WARD'

# Validated on the way IN rather than by a foreign key: orders placed before
# his.facilities existed carry codes with no row there, and a constraint would
# reject them retrospectively or demand invented backfill.
check "An order from an unknown facility is refused" \
    "[[ \$(api_curl -s -o /dev/null -w '%{http_code}' -X POST '${API}/lab-orders' \
        -H 'Content-Type: application/json' \
        -d '{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",\"facilityCode\":\"FAC-DOES-NOT-EXIST\"}') == 400 ]]"

check "An order from a known facility is accepted" \
    "[[ \$(api_curl -s -o /dev/null -w '%{http_code}' -X POST '${API}/lab-orders' \
        -H 'Content-Type: application/json' \
        -d '{\"patientId\":\"$PATIENT\",\"testCode\":\"$TEST_CODE\",\"facilityCode\":\"FAC-003\"}') == 201 ]]"

summary
