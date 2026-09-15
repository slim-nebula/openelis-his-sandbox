-- =============================================================================
-- Align the HIS test catalogue with the specimen each OpenELIS test accepts.
--
-- WHY
-- OpenELIS pre-fills the accessioning screen only when an order resolves to
-- exactly one test AND one specimen (see openelis/provision/01-loinc-mapping.sql).
-- Curating the OpenELIS side settled which specimen each test runs on; three of
-- ours disagreed with it, which would have had the HIS asking for Serum while
-- the LIS expected Plasma.
--
--   GLUC  Plasma -> Whole Blood   OpenELIS test 3 is Glucose(Whole Blood)
--   CREA  Serum  -> Plasma        OpenELIS test 4 is Creatinine(Plasma)
--   CHOL  Serum  -> Plasma        OpenELIS test 7 is Total Cholesterol(Plasma)
--
-- HCT is added because it was the control that proved the mechanism: a test
-- already unique on both axes in the seeded catalogue, which pre-filled the
-- wizard end to end while the other six did not.
--
-- DRIFT keeps its deliberately unmapped 99999-9 - the negative test relies on
-- OpenELIS rejecting an order it cannot resolve.
-- =============================================================================

UPDATE his.test_catalogue
   SET specimen_type = 'Whole Blood', specimen_snomed = '119297000'
 WHERE test_code = 'GLUC';

UPDATE his.test_catalogue
   SET specimen_type = 'Plasma', specimen_snomed = '119361006'
 WHERE test_code IN ('CREA', 'CHOL');

INSERT INTO his.test_catalogue
       (test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit, is_active)
VALUES ('HCT', 'Haematocrit', '20570-8', 'Whole Blood', '119297000', '%', true)
    ON CONFLICT (test_code) DO UPDATE
   SET test_name       = EXCLUDED.test_name,
       loinc_code      = EXCLUDED.loinc_code,
       specimen_type   = EXCLUDED.specimen_type,
       specimen_snomed = EXCLUDED.specimen_snomed,
       result_unit     = EXCLUDED.result_unit;
