-- =============================================================================
-- Where an order has got to inside the laboratory
--
-- Separate from order_status, deliberately.
--
-- order_status is the HIS's own lifecycle — CREATED, SENT_TO_LIS,
-- ACCEPTED_BY_LIS, RESULT_AVAILABLE — and the frontend, the test suites and the
-- bridge are all written against it. Folding laboratory progress into the same
-- column would change a published contract to add a detail, and would mean an
-- out-of-order event could push an order BACKWARDS from RESULT_AVAILABLE.
--
-- So progress is a refinement that sits underneath: it only means anything
-- while an order is ACCEPTED_BY_LIS, and it never contradicts the status.
-- =============================================================================

SET search_path TO his;

ALTER TABLE lab_orders
    -- IN_LABORATORY, AWAITING_VALIDATION. Null until the laboratory says
    -- something, which is honest: "we have not been told" is different from
    -- "nothing has happened".
    ADD COLUMN IF NOT EXISTS lab_progress    varchar(32),
    ADD COLUMN IF NOT EXISTS lab_progress_at timestamptz,

    -- The laboratory's own accession number. The single most useful thing on
    -- this table for a human: it is what a ward quotes on the telephone, and
    -- the only identifier both systems hold that a technician recognises.
    ADD COLUMN IF NOT EXISTS lab_accession   varchar(64);

-- Ranked so progress can only move forwards.
--
-- Kafka gives per-partition ordering, and these events are keyed by order
-- number, so they arrive in order per order — until a partition is added, a
-- consumer group rebalances mid-flight, or a replay is run to recover from an
-- incident. Any of those can deliver IN_LABORATORY after AWAITING_VALIDATION,
-- and a status that goes backwards is worse than one that lags: someone rings
-- the laboratory about a test that is already finished.
CREATE OR REPLACE FUNCTION his.lab_progress_rank(progress varchar) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE progress
        WHEN 'IN_LABORATORY'       THEN 10
        WHEN 'AWAITING_VALIDATION' THEN 20
        ELSE 0
    END
$$;

COMMENT ON COLUMN lab_orders.lab_progress IS
    'Laboratory-side progress within ACCEPTED_BY_LIS. Advances only; see '
    'his.lab_progress_rank and services/bridge/src/modules/results/progress.tracker.ts.';
