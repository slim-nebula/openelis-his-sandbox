-- =============================================================================
-- Let a corrected or retracted result through.
--
-- THE BUG
-- forwarded_results keyed on openelis_result_ref alone, and TryClaimResultAsync
-- claimed with ON CONFLICT DO NOTHING. OpenELIS issues a correction by UPDATING
-- the same DiagnosticReport - the id stays, meta.versionId increments - so the
-- claim failed, the correlator logged "already forwarded; skipping", and the
-- correction never reached the HIS. The clinician kept seeing the superseded
-- value with no indication anything had changed.
--
-- Retraction was worse: entered-in-error was not in the released statuses at
-- all, so a withdrawn result stayed on the HIS screen indefinitely.
--
-- The HIS side was already correct - lab_results_summary upserts
-- ON CONFLICT (openelis_result_ref) DO UPDATE - so a forwarded correction
-- overwrites the original in place. Only the bridge's claim needed fixing.
--
-- THE FIX
-- Claim per (result, version). Version 1 forwards, version 2 forwards again and
-- overwrites downstream, and a genuine redelivery of version 2 is still
-- suppressed. At-least-once delivery stays safe; corrections stop being
-- mistaken for duplicates.
--
-- Observed on the real release: DiagnosticReport arrived with meta.versionId
-- "1", its Observation "2", its ServiceRequest "3". OpenELIS populates the
-- field, so keying on it is sound rather than hopeful.
-- =============================================================================

ALTER TABLE bridge.forwarded_results
    ADD COLUMN IF NOT EXISTS version_id varchar(32) NOT NULL DEFAULT '1';

-- Rows written before this migration were forwarded from the first version of
-- their report; the default above records that rather than guessing later.
ALTER TABLE bridge.forwarded_results
    DROP CONSTRAINT IF EXISTS forwarded_results_pkey;

ALTER TABLE bridge.forwarded_results
    ADD CONSTRAINT forwarded_results_pkey
    PRIMARY KEY (openelis_result_ref, version_id);

-- Every version of one result belongs to the same order; this is the lookup the
-- correlator and any audit of "what did we send for this order" both want.
CREATE INDEX IF NOT EXISTS forwarded_results_order_idx
    ON bridge.forwarded_results (order_id, forwarded_at DESC);
