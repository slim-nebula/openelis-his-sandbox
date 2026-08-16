-- =============================================================================
-- OpenELIS provisioning: LOINC codes for the sandbox test catalogue
--
-- WHY THIS EXISTS
-- OpenELIS resolves an incoming FHIR order to one of its tests through exactly
-- one key: the http://loinc.org coding on ServiceRequest.code, matched against
-- clinlims.test.loinc (TaskInterpreterImpl.createTestFromFHIR). In the shipped
-- OpenELIS seed database NO test has a LOINC code, so without this step every
-- order the bridge sends is rejected with "no test found for SR".
--
-- The codes below must stay in step with his.test_catalogue in
-- db/his/001_schema.sql. Those two tables are the test-identity contract
-- between the two systems.
--
-- This is one-time SETUP against OpenELIS's own database, not runtime access:
-- nothing in the running sandbox reads or writes across the two databases.
-- The same changes can be made by hand in the OpenELIS admin UI under
-- Administration -> Test Management -> Test, by setting each test's LOINC code.
--
--   psql -h localhost -p 15432 -U clinlims -d clinlims -f 01-loinc-mapping.sql
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE sandbox_loinc_map (test_description text PRIMARY KEY, loinc text, his_code text) ON COMMIT DROP;

INSERT INTO sandbox_loinc_map (test_description, loinc, his_code) VALUES
    ('Hémoglobine(Whole Blood)',        '718-7',  'HGB'),
    ('Glucose(Plasma)',                 '2345-7', 'GLUC'),
    ('Créatinine(Serum)',               '2160-0', 'CREA'),
    ('Transaminases GPT (37°C)(Serum)', '1742-6', 'ALT'),
    ('Cholestérol total(Serum)',        '2093-3', 'CHOL'),
    ('Plaquette(Whole Blood)',          '777-3',  'PLT');

-- --- Fail loudly if the seed catalogue is not what we expect ----------------
DO $$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(m.test_description, ', ')
      INTO missing
      FROM sandbox_loinc_map m
     WHERE NOT EXISTS (
         SELECT 1 FROM clinlims.test t WHERE t.description = m.test_description
     );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Tests not found in this OpenELIS catalogue: %. '
            'Adjust openelis/provision/01-loinc-mapping.sql and his.test_catalogue to match.', missing;
    END IF;
END $$;

-- --- Stamp the codes --------------------------------------------------------
UPDATE clinlims.test t
   SET loinc = m.loinc,
       lastupdated = now()
  FROM sandbox_loinc_map m
 WHERE t.description = m.test_description;

-- --- A LOINC code that resolves to more than one test is ambiguous ----------
-- OpenELIS would silently take the first match, so refuse to leave the sandbox
-- in that state.
DO $$
DECLARE
    duplicated text;
BEGIN
    SELECT string_agg(loinc, ', ')
      INTO duplicated
      FROM (
          SELECT loinc FROM clinlims.test
           WHERE loinc IS NOT NULL AND loinc <> ''
           GROUP BY loinc HAVING count(*) > 1
      ) d;

    IF duplicated IS NOT NULL THEN
        RAISE EXCEPTION 'LOINC codes mapped to more than one test: %', duplicated;
    END IF;
END $$;

COMMIT;

-- --- Report -----------------------------------------------------------------
-- sample_types > 1 means an order without a Specimen resource lands on the
-- AwaitingSpecimen hold instead of going straight to Entered. The bridge always
-- sends a Specimen, so this is informational.
\echo ''
\echo 'Provisioned LOINC mappings:'
SELECT t.id           AS test_id,
       t.description  AS openelis_test,
       t.loinc        AS loinc_code,
       t.is_active    AS active,
       (SELECT count(*) FROM clinlims.sampletype_test st WHERE st.test_id = t.id) AS sample_types
  FROM clinlims.test t
 WHERE t.loinc IS NOT NULL AND t.loinc <> ''
 ORDER BY t.description;
