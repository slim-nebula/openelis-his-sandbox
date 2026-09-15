-- =============================================================================
-- The HIS mirror, keyed by (loinc, specimen) like the bridge.
--
-- The reasoning is in db/bridge/008_catalogue_specimen_key.sql and is not
-- repeated here. The short version: a LOINC code names what is measured, not
-- what it is measured in, and OpenELIS's catalogue has several tests per code.
-- 005's unique index on loinc_code alone made those impossible to mirror, so
-- 17 of 21 LOINC-coded tests never reached the doctor.
--
-- ON test_code
-- Discovered rows took the LOINC as their test_code — "unfamiliar to read, but
-- stable and unambiguous". Half of that is no longer true: the LOINC alone is
-- not unambiguous, so it cannot be a primary key here either. Discovered rows
-- now take `<loinc>|<specimen>`, which restores uniqueness and keeps the
-- property that mattered: derived only from what the laboratory told us, so it
-- is the same code on every sync and on every installation.
--
-- LOCAL rows keep whatever code they were given (GLUC, DRIFT). They are not the
-- sync's to rename, and lab_orders.test_code has a foreign key into this table —
-- an order placed last year must still say what test it was for.
-- =============================================================================

SET search_path TO his;

-- One LOINC may now name several orderable rows, provided they differ by
-- specimen. Two rows sharing both would be unresolvable by the laboratory, so
-- the pair stays unique.
DROP INDEX IF EXISTS his.test_catalogue_loinc_key;

CREATE UNIQUE INDEX IF NOT EXISTS test_catalogue_loinc_specimen_key
    ON his.test_catalogue (loinc_code, specimen_type);

COMMENT ON INDEX his.test_catalogue_loinc_specimen_key IS
    'What the laboratory resolves an order on. OpenELIS narrows candidate tests '
    'by LOINC and then by sample type, so the pair is the identity — not the code.';
