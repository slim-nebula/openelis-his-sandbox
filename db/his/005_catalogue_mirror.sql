-- =============================================================================
-- Turn his.test_catalogue into a mirror of what OpenELIS offers.
--
-- The HIS no longer decides which tests exist; OpenELIS does, and the bridge
-- discovers them. This table stays because it cannot simply be replaced by a
-- call to the bridge:
--
--   * lab_orders.test_code references it, so a test that has ever been ordered
--     can never be deleted, however long ago the laboratory withdrew it;
--   * the ordering screen must keep working while the bridge is down. Serving a
--     cached menu that is slightly stale beats serving an empty one.
--
-- WHAT SYNC MAY AND MAY NOT DO
-- A refresh matches on loinc_code, not test_code. LOINC is the identity both
-- systems share; test_code is a local label whose only job is to stay stable for
-- orders that already reference it. So a test discovered under a LOINC we
-- already know keeps its familiar code (HGB stays HGB) and only its name,
-- specimen and active flag are refreshed.
--
-- A test that disappears from OpenELIS is DEACTIVATED, never deleted. Deleting
-- would break the foreign key from historical orders, and an order placed last
-- year should still say which test it was for.
--
-- source distinguishes rows the bridge manages from rows we inject ourselves.
-- DRIFT is deliberately unmapped - the rejection suite depends on OpenELIS
-- refusing an order it cannot resolve - so a sync must leave it alone rather
-- than deactivate it for the entirely correct reason that OpenELIS has never
-- heard of it.
-- =============================================================================

ALTER TABLE his.test_catalogue
    ADD COLUMN IF NOT EXISTS source    varchar(16) NOT NULL DEFAULT 'DISCOVERED',
    ADD COLUMN IF NOT EXISTS synced_at timestamptz;

COMMENT ON COLUMN his.test_catalogue.source IS
    'DISCOVERED: managed by catalogue sync, deactivated when OpenELIS stops offering it. '
    'LOCAL: injected here on purpose and never touched by a sync.';

-- The deliberately unmapped fixture. OpenELIS has no test for 99999-9 and never
-- will, which is exactly what makes it useful.
UPDATE his.test_catalogue SET source = 'LOCAL' WHERE test_code = 'DRIFT';

-- Matching on LOINC needs LOINC to identify one row. It already does; this makes
-- that a rule rather than a coincidence, and makes the upsert expressible.
CREATE UNIQUE INDEX IF NOT EXISTS test_catalogue_loinc_key
    ON his.test_catalogue (loinc_code);

GRANT ALL ON his.test_catalogue TO his_app;
