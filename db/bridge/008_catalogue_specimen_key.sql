-- =============================================================================
-- A test is identified by LOINC **and specimen**, not by LOINC alone.
--
-- WHAT WAS ASSUMED
-- 003 made loinc the PRIMARY KEY, on the reasoning that LOINC is the one
-- identifier both systems agree on. That part is still true. What was wrong is
-- the assumption underneath it: that a LOINC code names exactly one orderable
-- thing.
--
-- It does not. In OpenELIS's own catalogue, 10351-5 is three tests — HIV viral
-- load on DBS, on plasma, and on serum — and 94547-7 is four. The code says
-- WHAT is measured; it does not say what it is measured IN.
--
-- WHAT THIS COST
-- With loinc as the key, those tests could not be represented at all, so the
-- sync dropped every one of them: 17 of OpenELIS's 21 LOINC-coded tests were
-- withheld from the doctor — every COVID, dengue, hepatitis B, hepatitis C and
-- HIV viral load test in the catalogue.
--
-- WHY IT IS SAFE TO CHANGE NOW
-- The rule existed because OpenELIS 3.2.1.11 could not resolve a specimen-
-- ambiguous order: it matched on the code alone, so an order for a shared LOINC
-- stalled at the accessioning screen. OpenELIS 3.2.2.0 changed that
-- (OGC-1145): LabOrderSearchProvider.createMapsForTests now narrows the
-- candidate (test, sample type) pairs by the sample type on the order, and
-- resolves cleanly when exactly one survives.
--
-- Verified on the running 3.2.2.0 instance, not assumed: an order for 10351-5
-- carrying a plasma Specimen imported as status 21 `Entered`, not status 29
-- `AwaitingSpecimen`.
--
-- WHAT REPLACES IT
-- (loinc, specimen_id) — the pair the laboratory actually resolves on. Two rows
-- may now share a LOINC as long as they differ by specimen, which is exactly
-- the shape OpenELIS's own catalogue has.
--
-- Still refused: two tests sharing BOTH a LOINC and a specimen. That is
-- genuinely unresolvable — no information in the order could separate them —
-- and the sync drops both rather than guessing.
-- =============================================================================

ALTER TABLE bridge.test_catalogue DROP CONSTRAINT IF EXISTS test_catalogue_pkey;

ALTER TABLE bridge.test_catalogue
    ADD CONSTRAINT test_catalogue_pkey PRIMARY KEY (loinc, specimen_id);

COMMENT ON TABLE bridge.test_catalogue IS
    'The orderable menu, keyed by (loinc, specimen_id). A LOINC code names what '
    'is measured; the specimen names what it is measured in. OpenELIS needs both '
    'to resolve an order to one test.';

COMMENT ON COLUMN bridge.test_catalogue.loinc IS
    'The wire contract, and half the key. Neither system sends its own internal '
    'test id: OpenELIS''s testId means nothing outside that installation, and the '
    'HIS test code means nothing outside the HIS.';

COMMENT ON COLUMN bridge.test_catalogue.specimen_name IS
    'Sent on the order as Specimen.type.text, and matched by OpenELIS against '
    'type_of_sample.description with STRING EQUALITY. A mismatch does not error — '
    'it silently falls back to treating the order as ambiguous.';
