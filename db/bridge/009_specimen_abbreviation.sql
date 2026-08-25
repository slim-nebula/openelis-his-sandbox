-- =============================================================================
-- Carry the sample type's LOCAL ABBREVIATION, not just its name.
--
-- OpenELIS binds an incoming order's test with
--   LabOrderSearchProvider.addToTestOrPanel
--     -> typeOfSampleService.getTypeOfSampleIdForLocalAbbreviation(code)
--     -> testService.getActiveTestByLoincCodeAndSampleType(loinc, sampleTypeId)
--
-- That first call is an exact lookup on clinlims.type_of_sample.local_abbrev,
-- which is NOT the display name we were storing:
--
--     description            local_abbrev
--     ---------------------  ------------
--     Serum                  Serum          <- same
--     Plasma                 Plasma         <- same
--     Whole Blood            Whole Bld      <- DIFFERENT
--     Respiratory Swab       Resp Swab      <- DIFFERENT
--
-- A miss returns null and OpenELIS falls through to `alltests.get(0)` - the
-- first active test for the LOINC - logging a warning and binding a test the
-- doctor did not order. Silent, and wrong in exactly the multi-specimen case
-- the per-specimen catalogue exists to serve.
--
-- Nullable, because a sync written by an older bridge has no value for it. The
-- sync refuses to offer a specimen without one, so rows that matter are filled.
-- =============================================================================

ALTER TABLE bridge.test_catalogue
    ADD COLUMN IF NOT EXISTS specimen_abbrev varchar(64);

COMMENT ON COLUMN bridge.test_catalogue.specimen_abbrev IS
    'type_of_sample.local_abbrev in OpenELIS. The only key OpenELIS resolves an '
    'order''s specimen by - see LabOrderSearchProvider.addToTestOrPanel. Differs '
    'from specimen_name for several stock sample types ("Whole Blood" is stored '
    'as "Whole Bld"), so the name cannot be substituted.';
