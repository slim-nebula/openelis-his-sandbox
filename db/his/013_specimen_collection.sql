-- =============================================================================
-- When the blood was actually drawn, and who was in a position to know.
--
-- THE PROBLEM
-- The results table could show only one time: when the laboratory signed the
-- result out. A doctor reading "released 11:30" five minutes later reasonably
-- concludes the value is current. If the blood was drawn at 06:00 it is five
-- and a half hours old, and the patient has had fluids since. Nothing on the
-- screen was wrong; there simply was not enough of it. ISO 15189:2022 7.4.1.7.a
-- requires the collection time when it matters for patient care, and it is
-- exactly this case that it matters for.
--
-- WHO OBSERVES THE DRAW DECIDES WHERE THE TIME COMES FROM
-- A collection time is a fact about a physical event, and only whoever watched
-- it can state it. That splits cleanly by patient class:
--
--   OUTPATIENT  the patient walks to the laboratory and a technician draws the
--               blood there. The laboratory observed it, records it in
--               sample_item.collection_date, and publishes it on
--               Specimen.collection.collected. We read it back.
--
--   INPATIENT   a nurse draws at the bedside. Nobody in the laboratory sees it.
--               If we do not capture it on the ward it is lost for good — the
--               accessioner can only type what someone wrote on the tube.
--
-- WHY AN INPATIENT ORDER WAITS
-- The draw happens AFTER the order is placed, so the collection time does not
-- exist at creation. It cannot be sent later either: once OpenELIS imports a
-- Task it moves the status off `requested` and never polls it again, so a
-- follow-up update would not be read.
--
-- So an inpatient order is held at AWAITING_COLLECTION and no outbox row is
-- written. Recording the draw writes the collection time and the outbox row in
-- one transaction, and the order dispatches then — carrying
-- Specimen.collection.collectedDateTime, which OpenELIS reads on import
-- (LabOrderSearchProvider.addCollection) and pre-fills onto the accessioner's
-- screen. One collection time, held identically by both systems.
--
-- Holding it is also the honest thing to do: until the tube exists there is
-- nothing for the laboratory to act on.
--
-- WHY TWO COLUMNS AND NOT ONE
-- lab_orders.collected_at is what the WARD recorded; lab_results_summary
-- .lab_collected_at is what the LABORATORY reported. They are different
-- observations and either can be absent, so collapsing them into one column
-- would lose which system is speaking. The API coalesces ours first — we do not
-- depend on the round trip for a fact we already hold, the same rule that keeps
-- visit_number at home.
--
-- WHY BOTH ARE NULLABLE
-- An outpatient order has no ward-recorded time by definition. And an inpatient
-- draw that nobody wrote down produces nothing — which must display as
-- "not recorded" rather than falling back to a received or released time. A
-- fabricated collection time is worse than none: it is indistinguishable from
-- an observed one, and a doctor will believe it.
-- =============================================================================

SET search_path TO his;

-- --- Which workflow this order follows ---------------------------------------
ALTER TABLE his.lab_orders
    ADD COLUMN IF NOT EXISTS patient_class varchar(16) NOT NULL DEFAULT 'OUTPATIENT';

ALTER TABLE his.lab_orders
    DROP CONSTRAINT IF EXISTS ck_lab_orders_patient_class;
ALTER TABLE his.lab_orders
    ADD CONSTRAINT ck_lab_orders_patient_class
    CHECK (patient_class IN ('OUTPATIENT', 'INPATIENT'));

-- --- What the ward recorded --------------------------------------------------
ALTER TABLE his.lab_orders
    ADD COLUMN IF NOT EXISTS collected_at timestamptz;

COMMENT ON COLUMN his.lab_orders.collected_at IS
    'When the ward drew the specimen. Inpatient orders only; an outpatient draw '
    'is observed by the laboratory and read back instead. Null means not recorded.';

-- An inpatient order waits here until the draw is recorded. No outbox row is
-- written while it does, so nothing reaches the laboratory.
ALTER TABLE his.lab_orders
    DROP CONSTRAINT IF EXISTS ck_lab_orders_status;
ALTER TABLE his.lab_orders
    ADD CONSTRAINT ck_lab_orders_status CHECK (order_status IN (
        'CREATED', 'AWAITING_COLLECTION', 'SENT_TO_LIS', 'ACCEPTED_BY_LIS',
        'REJECTED_BY_LIS', 'RESULT_AVAILABLE', 'FAILED'));

-- The ward's worklist: what has been ordered and not yet drawn.
CREATE INDEX IF NOT EXISTS ix_lab_orders_awaiting_collection
    ON his.lab_orders (created_at DESC)
 WHERE order_status = 'AWAITING_COLLECTION';

-- --- What the laboratory reported --------------------------------------------
ALTER TABLE his.lab_results_summary
    ADD COLUMN IF NOT EXISTS lab_collected_at timestamptz;

COMMENT ON COLUMN his.lab_results_summary.lab_collected_at IS
    'Collection time as reported by the laboratory, from '
    'Specimen.collection.collected. NEVER from Observation.effective, which '
    'OpenELIS populates with the analysis RELEASE date.';

GRANT SELECT, INSERT, UPDATE ON his.lab_orders TO his_app;
GRANT SELECT, INSERT, UPDATE ON his.lab_results_summary TO his_app;
