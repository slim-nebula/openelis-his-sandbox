#!/usr/bin/env bash
# =============================================================================
# Clears every order, result and order-derived patient from all three databases,
# leaving configuration and seed data intact.
#
# WHAT IT KEEPS, deliberately:
#   his.test_catalogue, his.integration_mappings  - the test-identity contract
#   clinlims.site_information                     - incl. ACCEPT_EXTERNAL_ORDERS,
#                                                   which is set by hand in the
#                                                   OpenELIS admin UI
#   clinlims.test                                 - the seeded catalogue, LOINC
#                                                   codes included
#   HAPI Subscription / Practitioner / Questionnaire / Organization
#
# WHAT IT DOES NOT TOUCH:
#   The HAPI FHIR resource tables (hfj_*). Stale Task/ServiceRequest/Specimen
#   rows there are unreachable once electronic_order is empty - nothing queries
#   them by anything but an id that will never be minted again - and hand-
#   deleting rows across HAPI's fifteen index tables risks corrupting its search
#   index for no visible gain. Use `make clean` if you want those gone too.
#
# Kafka is left alone on purpose: consumer offsets are already committed past
# every existing message, so old events are never redelivered.
#
#   ./scripts/reset-orders.sh          # prompts
#   ./scripts/reset-orders.sh --yes    # no prompt
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a; source .env; set +a

his()    { docker exec -i -e PGPASSWORD="$HIS_DB_ADMIN_PASSWORD" his-db-external \
             psql -v ON_ERROR_STOP=1 -U "$HIS_DB_ADMIN_USER" -d "$HIS_DB_NAME" -tAX "$@"; }
bridge() { docker exec -i -e PGPASSWORD="$HIS_DB_ADMIN_PASSWORD" his-db-external \
             psql -v ON_ERROR_STOP=1 -U "$HIS_DB_ADMIN_USER" -d "$BRIDGE_DB_NAME" -tAX "$@"; }
oe()     { docker exec -i -e PGPASSWORD="$OE_DB_PASSWORD" openelis-db-external \
             psql -v ON_ERROR_STOP=1 -U "$OE_DB_USER" -d "$OE_DB_NAME" -tAX "$@"; }

echo "==> Current state"
printf '    his.lab_orders            %s\n' "$(his -c 'SELECT count(*) FROM his.lab_orders;')"
printf '    his.patients              %s\n' "$(his -c 'SELECT count(*) FROM his.patients;')"
printf '    bridge.fhir_resources     %s\n' "$(bridge -c 'SELECT count(*) FROM bridge.fhir_resources;')"
printf '    clinlims.electronic_order %s\n' "$(oe -c 'SELECT count(*) FROM clinlims.electronic_order;')"
printf '    clinlims.patient          %s\n' "$(oe -c 'SELECT count(*) FROM clinlims.patient;')"
printf '    clinlims.sample           %s\n' "$(oe -c 'SELECT count(*) FROM clinlims.sample;')"

if [[ "${1:-}" != "--yes" ]]; then
    read -r -p "Delete all of the above? [y/N] " reply
    [[ "$reply" == [yY] ]] || { echo "Aborted."; exit 1; }
fi

# --- OpenELIS --------------------------------------------------------------
# Ordered by dependency. A sample row would pin an electronic_order through
# sample_electronic_order_fk, so refuse rather than half-delete if any exist.
echo "==> OpenELIS"
oe <<'SQL'
BEGIN;

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM clinlims.sample;
    IF n > 0 THEN
        RAISE EXCEPTION
            'clinlims.sample has % row(s). Accessioned samples are real lab work; '
            'this script will not delete them. Use `make clean` for a full wipe.', n;
    END IF;
END $$;

DELETE FROM clinlims.electronic_order;

-- Patients here exist only because the bridge sent them. Nothing in the seed
-- catalogue references them, and every dependent table below is empty in a
-- sandbox that has never accessioned a sample.
CREATE TEMP TABLE doomed_person ON COMMIT DROP AS
    SELECT person_id FROM clinlims.patient;

DELETE FROM clinlims.patient_identity  WHERE patient_id IN (SELECT id FROM clinlims.patient);
DELETE FROM clinlims.patient_patient_type WHERE patient_id IN (SELECT id FROM clinlims.patient);
DELETE FROM clinlims.patient;
-- A person row can wear more than one hat: OpenELIS reuses the same table for
-- the requesting practitioner it created from the order's Practitioner
-- resource. Leave anything still referenced as a provider or a contact alone -
-- deleting it would strip a requester the seed data or a future order needs.
DELETE FROM clinlims.person_address
 WHERE person_id IN (SELECT person_id FROM doomed_person)
   AND person_id NOT IN (SELECT person_id FROM clinlims.provider WHERE person_id IS NOT NULL);

DELETE FROM clinlims.person p
 WHERE p.id IN (SELECT person_id FROM doomed_person)
   AND NOT EXISTS (SELECT 1 FROM clinlims.provider                  x WHERE x.person_id = p.id)
   AND NOT EXISTS (SELECT 1 FROM clinlims.organization_contact      x WHERE x.person_id = p.id)
   AND NOT EXISTS (SELECT 1 FROM clinlims.external_connection_contact x WHERE x.person_id = p.id);

COMMIT;
SQL

# --- Bridge ----------------------------------------------------------------
# Its whole content is per-order state: the mirrored FHIR store, the inbound
# dedupe ledger, the outbound result ledger and the order tracker.
echo "==> Bridge"
bridge -c "TRUNCATE bridge.fhir_resources,
                    bridge.received_resources,
                    bridge.processed_events,
                    bridge.forwarded_results,
                    bridge.order_tracking,
                    bridge.dead_letters;" >/dev/null

# --- HIS -------------------------------------------------------------------
echo "==> HIS"
his -c "TRUNCATE his.lab_order_events,
                 his.lab_results_summary,
                 his.outbox,
                 his.lab_orders,
                 his.patients CASCADE;" >/dev/null

# The demo patient from 001_schema.sql is seed data, not test data: the
# rejection and negative suites post orders against its fixed uuid rather than
# creating a patient of their own. Truncating patients removes it, and both
# suites then fail at "Order accepted by the HIS" with an empty response - a
# foreign key violation that looks nothing like its cause. Restore it.
his -c "INSERT INTO his.patients
            (patient_id, mrn, first_name, last_name, sex, date_of_birth, phone, national_id)
        VALUES ('11111111-1111-1111-1111-111111111111', 'MRN-000001',
                'Amina', 'Traore', 'F', '1988-04-17', '+22370000001', 'NID-000001')
        ON CONFLICT (patient_id) DO NOTHING;" >/dev/null

# The MRN sequence is independent of the table, so TRUNCATE leaves it where it
# was. Wind it back to just past the seeded patient, otherwise MRNs climb
# forever across resets and stop matching the row count anyone eyeballing the
# table expects.
his -c "SELECT setval('his.mrn_seq',
            (SELECT coalesce(max(substring(mrn from '^MRN-([0-9]+)\$')::bigint), 1)
               FROM his.patients));" >/dev/null

# --- Verify ----------------------------------------------------------------
echo "==> After"
fail=0
check() {  # check <label> <expected> <actual>
    printf '    %-26s %s' "$1" "$3"
    if [[ "$3" == "$2" ]]; then echo "  ok"; else echo "  EXPECTED $2"; fail=1; fi
}
check "his.lab_orders"            0 "$(his    -c 'SELECT count(*) FROM his.lab_orders;')"
check "his.patients"              0 "$(his    -c 'SELECT count(*) FROM his.patients;')"
check "his.outbox"                0 "$(his    -c 'SELECT count(*) FROM his.outbox;')"
check "bridge.fhir_resources"     0 "$(bridge -c 'SELECT count(*) FROM bridge.fhir_resources;')"
check "bridge.order_tracking"     0 "$(bridge -c 'SELECT count(*) FROM bridge.order_tracking;')"
check "clinlims.electronic_order" 0 "$(oe     -c 'SELECT count(*) FROM clinlims.electronic_order;')"
check "clinlims.patient"          0 "$(oe     -c 'SELECT count(*) FROM clinlims.patient;')"
# The suites post orders against this uuid; without it they fail in a way that
# gives no hint the reset caused it.
check "seeded demo patient"       1 "$(his -c \
    \"SELECT count(*) FROM his.patients WHERE patient_id = '11111111-1111-1111-1111-111111111111';\")"

# Configuration must have survived, or the next order silently regresses to the
# empty-patient behaviour this sandbox was fixed to avoid.
ext=$(oe -c "SELECT value FROM clinlims.site_information WHERE name = 'external orders';")
printf '    %-26s %s' "'external orders'" "$ext"
if [[ "$ext" == "true" ]]; then echo "  ok"; else
    echo "  EXPECTED true - set it under Admin -> Configuration, or orders arrive with no patient"
    fail=1
fi
printf '    %-26s %s\n' "his.test_catalogue" "$(his -c 'SELECT count(*) FROM his.test_catalogue;')"

[[ $fail -eq 0 ]] || { echo "==> Reset incomplete."; exit 1; }
echo "==> Clean."
