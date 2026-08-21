-- =============================================================================
-- Undo the catalogue curation that 01-loinc-mapping.sql used to apply.
--
-- WHY IT WAS APPLIED
-- OpenELIS binds an incoming order only when the LOINC code resolves to exactly
-- one active test AND that test accepts exactly one specimen. None of the seven
-- tests the HIS offered satisfied both, so every order stalled at the
-- accessioning screen waiting for a human to pick the test. The fix at the time
-- was to reshape OpenELIS's catalogue until our tests were unambiguous.
--
-- WHY IT IS BEING UNDONE
-- That worked, but it was the wrong side to change. The integration should read
-- the laboratory system, never reshape it - the LIS is the accredited component,
-- and edits to its seeded catalogue are edits an auditor would rightly ask about.
--
-- Catalogue discovery removes the need entirely. The bridge now asks OpenELIS
-- which tests are unambiguous and offers only those, so ambiguity is handled by
-- not offering the test rather than by editing the test.
--
-- WHAT THIS DOES TO THE MENU
-- Restoring the duplicates makes four tests ambiguous again, so discovery will
-- stop offering them: Haemoglobin, Glucose, Creatinine and Total Cholesterol.
-- That is not a regression. Those orders could never have been accessioned
-- unattended; the ambiguity was always there, and curation had hidden it. To
-- make them orderable the LABORATORY resolves them in Administration -> Test
-- Management - one LOINC per test, one specimen per test - which is a decision
-- about the laboratory's own catalogue, made by the people who own it.
--
--   docker exec -i openelis-db-external psql -U clinlims -d clinlims \
--     < openelis/provision/undo-catalogue-curation.sql
--   docker restart openelis-webapp     # sample-type bindings are cached
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- --- 1. The duplicate LOINC codes that were cleared --------------------------
UPDATE clinlims.test SET loinc = '1742-6', lastupdated = now() WHERE id = 1;   -- GPT ALAT(Serum)
UPDATE clinlims.test SET loinc = '777-3',  lastupdated = now() WHERE id = 20;  -- Platelets(Whole Blood)

-- --- 2. The specimen bindings that were deleted ------------------------------
-- Original ids and display_order, taken from the pre-change dump rather than
-- invented, so the rows come back exactly as they were.
INSERT INTO clinlims.sampletype_test (id, sample_type_id, test_id, is_panel, display_order)
VALUES (255, 2, 15, false, NULL),   -- Serum  on Hemoglobin Bld
       (261, 2,  3, false, NULL),   -- Serum  on Glucose
       (3,   3,  3, false, 1),      -- Plasma on Glucose
       (4,   2,  4, false, 3),      -- Serum  on Creatinine
       (7,   2,  7, false, 5)       -- Serum  on Total Cholesterol
    ON CONFLICT (id) DO NOTHING;

COMMIT;

\echo ''
\echo 'Catalogue restored. Each of these should now report more than one again:'
SELECT t.id,
       t.description,
       (SELECT count(*) FROM clinlims.test x WHERE x.loinc = t.loinc AND x.is_active = 'Y') AS tests_sharing_loinc,
       (SELECT count(*) FROM clinlims.sampletype_test st WHERE st.test_id = t.id) AS specimens
  FROM clinlims.test t
 WHERE t.id IN (1, 3, 4, 7, 15, 20, 380, 386)
 ORDER BY t.id;
