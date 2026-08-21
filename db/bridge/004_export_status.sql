-- =============================================================================
-- Watch the channel OpenELIS pushes results down.
--
-- THE GAP THIS CLOSES
-- If OpenELIS stopped pushing released results, nothing in this sandbox would
-- notice. The bridge would sit receiving nothing, which is indistinguishable
-- from a laboratory that simply has no results ready. Orders would pile up in
-- ACCEPTED_BY_LIS and the first person to spot it would be a clinician asking
-- why a result never came back - which is far too late and far too human a
-- detection mechanism.
--
-- OpenELIS already knows the answer. /rest/DataExportStatus reports the health
-- of each push subscription BY ENDPOINT, including ours:
--
--   { "endpoint": "http://bridge:8080/fhir", "lastStatus": "SUCCEEDED",
--     "lastSuccess": "...", "failedLast24h": 0, "totalLast24h": 120,
--     "maxIntervalMinutes": 1 }
--
-- maxIntervalMinutes is the cadence OpenELIS intends to keep, which means
-- staleness can be derived from what the system says about itself rather than
-- from a threshold we guessed.
--
-- WHY THIS ONE IS POLLED WHEN THE CATALOGUE IS NOT
-- The test menu changes a handful of times a year, so a timer would mostly run
-- for nothing and would hide changes from the person who caused them. Export
-- health changes minute to minute and nobody presses a button to ask about it.
-- Different question, different answer.
--
-- History is kept rather than a single current row: "it broke and recovered
-- twice overnight" is a different problem from "it has been down since 03:00",
-- and only a series can tell them apart.
-- =============================================================================

CREATE TABLE IF NOT EXISTS bridge.export_status_checks (
    id                  bigserial   PRIMARY KEY,
    checked_at          timestamptz NOT NULL DEFAULT now(),
    subscription_id     varchar(32),
    endpoint            varchar(255),
    verdict             varchar(16) NOT NULL,   -- OK | STALE | FAILING | UNREACHABLE
    last_status         varchar(32),
    last_success        timestamptz,
    last_attempt        timestamptz,
    failed_last_24h     integer,
    total_last_24h      integer,
    max_interval_minutes integer,
    detail              text
);

CREATE INDEX IF NOT EXISTS export_status_checks_recent_idx
    ON bridge.export_status_checks (checked_at DESC);

GRANT ALL ON bridge.export_status_checks TO bridge_app;
GRANT USAGE, SELECT ON SEQUENCE bridge.export_status_checks_id_seq TO bridge_app;
