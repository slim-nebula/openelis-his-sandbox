-- =============================================================================
-- The test menu, discovered from OpenELIS rather than maintained by hand.
--
-- WHY THIS TABLE EXISTS
-- The HIS and OpenELIS previously kept independent catalogues, and they drifted:
-- three tests asked for a specimen OpenELIS does not accept, two resolved to a
-- LOINC code shared by two tests, and four resolved to a test accepting several
-- specimens. Every one of those made OpenELIS refuse to bind the order, so the
-- accessioner picked the test by hand on every single order.
--
-- OpenELIS knows its own menu, including which tests the laboratory has switched
-- on for the analysers it owns. This table is a cache of that answer, refreshed
-- on demand. It is not a second source of truth: rows only ever arrive from a
-- sync, and a sync only ever reflects what OpenELIS said.
--
-- ONLY UNAMBIGUOUS TESTS ARE STORED. A test reaches this table only if OpenELIS
-- reports it active AND orderable AND carrying exactly one LOINC code AND bound
-- to exactly one specimen. Anything else would arrive at the accessioning screen
-- as an unresolvable order, so it is better never offered to the doctor.
-- =============================================================================

CREATE TABLE IF NOT EXISTS bridge.test_catalogue (
    loinc          varchar(32)  PRIMARY KEY,
    openelis_test_id varchar(32) NOT NULL,
    name           varchar(255) NOT NULL,
    specimen_name  varchar(128) NOT NULL,
    specimen_id    varchar(32)  NOT NULL,
    result_unit    varchar(64),
    synced_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON COLUMN bridge.test_catalogue.loinc IS
    'The wire contract. Neither system sends its own internal test id: OpenELIS''s '
    'testId means nothing outside that installation, and the HIS test code means '
    'nothing outside the HIS. LOINC is what both sides agree on, so it is the key.';

COMMENT ON COLUMN bridge.test_catalogue.openelis_test_id IS
    'Recorded for diagnostics only. Never sent on an order.';

-- --- Sync history -----------------------------------------------------------
-- Manual sync means a human decides when the menu changes, so there must be a
-- record of who changed it and what changed. This is also what lets a sync
-- refuse to apply a suspicious result: it can compare against the last one.
CREATE TABLE IF NOT EXISTS bridge.catalogue_syncs (
    id           bigserial   PRIMARY KEY,
    started_at   timestamptz NOT NULL DEFAULT now(),
    finished_at  timestamptz,
    status       varchar(32) NOT NULL,          -- SUCCEEDED | REJECTED | FAILED
    tests_before integer     NOT NULL DEFAULT 0,
    tests_after  integer     NOT NULL DEFAULT 0,
    added        text,                          -- comma separated LOINC codes
    removed      text,
    changed      text,
    detail       text                           -- why a sync was rejected or failed
);

CREATE INDEX IF NOT EXISTS catalogue_syncs_started_idx
    ON bridge.catalogue_syncs (started_at DESC);

-- --- Grants -----------------------------------------------------------------
-- GRANT ALL ON ALL TABLES in 001_schema.sql covered only the tables that existed
-- when it ran, so every migration that adds a table has to grant on it. Missing
-- it produces "permission denied for table" from the application while psql as
-- the admin user works perfectly, which is a confusing way to spend an hour.
GRANT ALL ON bridge.test_catalogue  TO bridge_app;
GRANT ALL ON bridge.catalogue_syncs TO bridge_app;
GRANT USAGE, SELECT ON SEQUENCE bridge.catalogue_syncs_id_seq TO bridge_app;

-- And stop the next migration having to remember.
ALTER DEFAULT PRIVILEGES IN SCHEMA bridge GRANT ALL ON TABLES TO bridge_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA bridge GRANT USAGE, SELECT ON SEQUENCES TO bridge_app;
