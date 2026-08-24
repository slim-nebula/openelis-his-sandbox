-- =============================================================================
-- Hand each order to the laboratory once at a time.
--
-- THE PROBLEM THIS SOLVES, AND WHOSE IT IS
-- OpenELIS polls `Task?status=requested&owner=...` and imports what comes back.
-- On a clean rebuild of this stack it was observed importing the SAME Task twice
-- within two seconds:
--
--   22:12:30 WARN  FhirApiWorkFlowServiceImpl.getTaskLoctionFromServer   <- pass 1
--   22:12:32 WARN  FhirApiWorkFlowServiceImpl.getTaskLoctionFromServer   <- pass 2
--   22:12:35 ERROR HTTP 409 HAPI-0825: client-assigned ID constraint failure
--   22:12:35 ERROR beginTaskImportOrderPath: could not process Task ...
--
-- Both passes create FHIR resources with client-assigned ids; the loser gets a
-- 409 and the whole import aborts. The Task is then never acknowledged, so it
-- stays `requested`, so the next poll finds it again — for ever. One order was
-- re-imported every 30 seconds for twenty-six minutes, and one of those passes
-- left a DUPLICATE row in clinlims.patient.
--
-- That defect is inside OpenELIS and is not ours to fix (defect 0 in
-- docs/catalogue-discovery-plan.md). But the collision needs two overlapping
-- deliveries, and who delivers is entirely ours.
--
-- WHAT A LEASE IS, AND WHAT IT IS NOT
-- When the poll returns a Task, that delivery is recorded and the Task is
-- withheld from later polls until the lease expires.
--
--   * It does NOT change the Task. The status stays `requested`, because that
--     is what it truthfully is; GET /fhir/Task/{id} returns it unchanged. Only
--     the SEARCH withholds it, and only for a bounded time.
--   * It does NOT abandon anything. When the lease expires the Task is offered
--     again, so a genuinely failed import still retries — just never
--     concurrently with itself. Deciding an order is dead is a clinical call
--     and is deliberately not made here.
--
-- This is the visibility-timeout every work queue uses, applied at the only
-- point in this integration where we have any say.
--
-- `deliveries` is a second thing worth having. OpenELIS has no attempt counter
-- for a failing import, so nothing anywhere counts how many times an order has
-- been handed over and not acknowledged. This does.
-- =============================================================================

SET search_path TO bridge;

CREATE TABLE IF NOT EXISTS bridge.delivery_leases (
    resource_id  varchar(64)  PRIMARY KEY,
    leased_until timestamptz  NOT NULL,
    deliveries   integer      NOT NULL DEFAULT 1,
    first_at     timestamptz  NOT NULL DEFAULT now(),
    last_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE bridge.delivery_leases IS
    'One row per Task handed to the LIS. Withholds it from the poll until the '
    'lease expires, so one order cannot be imported twice at once.';
COMMENT ON COLUMN bridge.delivery_leases.deliveries IS
    'How many times this Task has been handed over. Above 1 means the LIS took '
    'it and never acknowledged it — the attempt counter OpenELIS does not keep.';

-- The poll filters on expiry every time it runs, which is the hottest predicate
-- this table has.
CREATE INDEX IF NOT EXISTS ix_delivery_leases_until
    ON bridge.delivery_leases (leased_until);

GRANT SELECT, INSERT, UPDATE, DELETE ON bridge.delivery_leases TO bridge_app;
