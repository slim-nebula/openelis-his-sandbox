-- =============================================================================
-- Allocate MRNs from a sequence instead of counting rows.
--
-- THE BUG
-- NextMrnAsync derived the MRN from `SELECT count(*) + 1 FROM his.patients`,
-- which is wrong in two ways that both surface as a failed registration:
--
--   * it is not stable under deletion. Remove a patient and the count drops, so
--     the next MRN collides with one already issued. scripts/reset-orders.sh
--     made this reproducible: after a reset the seeded demo patient holds
--     MRN-000001 and the next patient created through the UI is assigned the
--     same number.
--   * it races. Two registrations running concurrently read the same count and
--     compute the same MRN.
--
-- The unique constraint on external_patient_id caught both, so no duplicate MRN
-- was ever stored - the failure mode is a registration that errors rather than
-- data corruption. That is the right guard, but it is a last line of defence,
-- not an allocation strategy.
--
-- A sequence is atomic, monotonic, and indifferent to deletes. Numbers are
-- consumed on rollback, so the series may have gaps; an MRN is an identifier,
-- not a count, so gaps do not matter.
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS his.mrn_seq AS bigint START WITH 1 INCREMENT BY 1;

-- Start above every MRN already issued, so this migration cannot reissue one.
-- Existing values are MRN-000123; anything not matching that shape is ignored
-- rather than guessed at.
SELECT setval(
    'his.mrn_seq',
    GREATEST(
        (SELECT coalesce(max(substring(external_patient_id from '^MRN-([0-9]+)$')::bigint), 0)
           FROM his.patients),
        1
    )
);

GRANT USAGE, SELECT ON SEQUENCE his.mrn_seq TO his_app;
