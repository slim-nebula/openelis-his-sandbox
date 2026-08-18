-- =============================================================================
-- OpenELIS provisioning: make the sandbox test catalogue unambiguous
--
-- WHY THIS EXISTS
-- OpenELIS resolves an incoming FHIR order to one of its tests through the
-- http://loinc.org coding on ServiceRequest.code, matched against
-- clinlims.test.loinc. Matching alone is not enough: for the accessioning UI to
-- pre-fill the specimen and the test, the match must be UNAMBIGUOUS in two
-- separate ways.
--
--   1. The LOINC code must resolve to exactly ONE active test.
--      The seeded catalogue maps 1742-6 to both ALT(Serum) and GPT ALAT(Serum),
--      and 777-3 to both Platelet Count and Platelets.
--
--   2. That test must accept exactly ONE sample type.
--      Hemoglobin Bld accepts Serum and Whole Blood; Glucose accepts three.
--      OpenELIS does NOT use the Specimen we send to narrow this down - we send
--      ServiceRequest.specimen -> Specimen.type.text = 'Whole Blood' with the
--      SNOMED coding, and it still returns every candidate.
--
-- If either check fails, LabOrderSearchProvider returns the orderable under
-- <crosstests> instead of <sampleTypes>, and the accessioner has to pick the
-- test by hand on every order. Worse, the React wizard in 3.2.1.11 reads
-- order.crosstest (singular) while the provider emits order.crosstests, so the
-- chooser never renders and the accessioner gets no hint at all.
--
-- Verified behaviour, same patient, same day:
--   ambiguous test -> "sampleTypes": "",  "crosstests": { ... }
--   clean test     -> "sampleTypes": { "sampleType": { "name": "Whole Blood",
--                       "tests": { "test": { "name": "Hematocrit" } } } }
--
-- This is one-time SETUP against OpenELIS's own database, not runtime access:
-- nothing in the running sandbox reads or writes across the two databases. The
-- same edits can be made by hand under Administration -> Test Management.
--
-- The mapping below must stay in step with his.test_catalogue in
-- db/his/001_schema.sql. Those two tables are the test-identity contract.
--
-- RESTART REQUIRED
-- OpenELIS caches the sample-type/test bindings in memory. After this script
-- runs, the database is correct but the running webapp keeps answering from the
-- stale cache and still reports the test as ambiguous. `make provision`
-- restarts the webapp for that reason; if you run the SQL by hand, restart it
-- yourself or the change will look like it did nothing.
--
--   make provision
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- test_id is the OpenELIS test we keep for this LOINC; sample_type_id is the
-- single specimen we keep bound to it. Both are asserted below, never guessed.
CREATE TEMP TABLE sandbox_catalogue (
    his_code       text PRIMARY KEY,
    loinc          text NOT NULL,
    test_id        integer NOT NULL,
    test_desc      text NOT NULL,
    sample_type_id integer NOT NULL,
    sample_type    text NOT NULL
) ON COMMIT DROP;

INSERT INTO sandbox_catalogue VALUES
    ('HGB',  '718-7',   15, 'Hemoglobin Bld(Whole Blood)',   4, 'Whole Blood'),
    ('GLUC', '2345-7',   3, 'Glucose(Whole Blood)',          4, 'Whole Blood'),
    ('CREA', '2160-0',   4, 'Creatinine(Plasma)',            3, 'Plasma'),
    ('CHOL', '2093-3',   7, 'Total Cholesterol(Plasma)',     3, 'Plasma'),
    ('ALT',  '1742-6', 386, 'ALT(Serum)',                    2, 'Serum'),
    ('PLT',  '777-3',  380, 'Platelet Count(Whole Blood)',   4, 'Whole Blood'),
    ('HCT',  '20570-8', 16, 'Hematocrit(Whole Blood)',       4, 'Whole Blood');

-- --- Refuse to run against a catalogue that is not what we expect -----------
DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(format('%s (expected test %s "%s")', c.his_code, c.test_id, c.test_desc), '; ')
      INTO bad
      FROM sandbox_catalogue c
     WHERE NOT EXISTS (SELECT 1 FROM clinlims.test t
                        WHERE t.id = c.test_id AND t.description = c.test_desc);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'OpenELIS catalogue does not match expectations: %', bad;
    END IF;

    SELECT string_agg(format('%s (expected sample type %s "%s")', c.his_code, c.sample_type_id, c.sample_type), '; ')
      INTO bad
      FROM sandbox_catalogue c
     WHERE NOT EXISTS (SELECT 1 FROM clinlims.type_of_sample ts
                        WHERE ts.id = c.sample_type_id AND ts.description = c.sample_type);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'OpenELIS sample types do not match expectations: %', bad;
    END IF;
END $$;

-- Curating the catalogue means unbinding specimens. Results already recorded
-- against those bindings are real lab work, so stop rather than orphan them.
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n
      FROM clinlims.analysis a
      JOIN sandbox_catalogue c ON c.test_id = a.test_id;
    IF n > 0 THEN
        RAISE EXCEPTION 'There are % analysis row(s) on tests this script re-binds. '
            'Curate the catalogue through the admin UI instead.', n;
    END IF;
END $$;

-- --- 1. Stamp the codes we own ---------------------------------------------
UPDATE clinlims.test t
   SET loinc = c.loinc, lastupdated = now()
  FROM sandbox_catalogue c
 WHERE t.id = c.test_id AND t.loinc IS DISTINCT FROM c.loinc;

-- --- 2. One LOINC, one test -------------------------------------------------
-- Any OTHER test carrying one of our codes is cleared. The test itself is left
-- active and orderable inside OpenELIS; it simply stops answering to a code the
-- HIS uses, so an incoming order can only land on the test we chose.
UPDATE clinlims.test t
   SET loinc = NULL, lastupdated = now()
  FROM sandbox_catalogue c
 WHERE t.loinc = c.loinc
   AND t.id <> c.test_id;

-- --- 3. One test, one specimen ---------------------------------------------
DELETE FROM clinlims.sampletype_test st
 USING sandbox_catalogue c
 WHERE st.test_id = c.test_id
   AND st.sample_type_id <> c.sample_type_id;

-- Ensure the binding we want actually exists (it does in the seed data, but a
-- missing row here would silently make the test unorderable).
-- sampletype_test.id has no sequence default in this schema, so allocate above
-- the current maximum rather than relying on one.
INSERT INTO clinlims.sampletype_test (id, test_id, sample_type_id, is_panel)
SELECT (SELECT coalesce(max(id), 0) FROM clinlims.sampletype_test)
           + row_number() OVER (ORDER BY c.his_code),
       c.test_id, c.sample_type_id, false
  FROM sandbox_catalogue c
 WHERE NOT EXISTS (SELECT 1 FROM clinlims.sampletype_test st
                    WHERE st.test_id = c.test_id AND st.sample_type_id = c.sample_type_id);

-- --- 4. Prove it -----------------------------------------------------------
DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(format('%s -> %s test(s)', c.loinc, n.cnt), ', ')
      INTO bad
      FROM sandbox_catalogue c
      JOIN LATERAL (SELECT count(*) AS cnt FROM clinlims.test t
                     WHERE t.loinc = c.loinc AND t.is_active = 'Y') n ON true
     WHERE n.cnt <> 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'LOINC codes still ambiguous: %', bad;
    END IF;

    SELECT string_agg(format('%s -> %s sample type(s)', c.test_desc, n.cnt), ', ')
      INTO bad
      FROM sandbox_catalogue c
      JOIN LATERAL (SELECT count(*) AS cnt FROM clinlims.sampletype_test st
                     WHERE st.test_id = c.test_id) n ON true
     WHERE n.cnt <> 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Tests still accept more than one specimen: %', bad;
    END IF;
END $$;

COMMIT;

-- --- Report -----------------------------------------------------------------
-- sandbox_catalogue was ON COMMIT DROP, so the report restates the mapping.
\echo ''
\echo 'Provisioned catalogue (tests_for_loinc and sample_types must both read 1):'
SELECT c.his_code,
       c.loinc,
       t.description AS openelis_test,
       (SELECT count(*) FROM clinlims.test x WHERE x.loinc = c.loinc AND x.is_active = 'Y') AS tests_for_loinc,
       (SELECT count(*) FROM clinlims.sampletype_test st WHERE st.test_id = c.test_id) AS sample_types,
       (SELECT ts.description FROM clinlims.sampletype_test st
          JOIN clinlims.type_of_sample ts ON ts.id = st.sample_type_id
         WHERE st.test_id = c.test_id LIMIT 1) AS specimen
  FROM (VALUES ('ALT','1742-6',386), ('CHOL','2093-3',7), ('CREA','2160-0',4),
               ('GLUC','2345-7',3),  ('HCT','20570-8',16), ('HGB','718-7',15),
               ('PLT','777-3',380)
       ) AS c(his_code, loinc, test_id)
  JOIN clinlims.test t ON t.id = c.test_id
 ORDER BY c.his_code;
