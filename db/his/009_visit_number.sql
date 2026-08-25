-- =============================================================================
-- Which visit the order was placed during.
--
-- WHY THIS EXISTS
-- A patient has one permanent file number (MRN) and many visits. When a result
-- comes back from the laboratory, the hospital has to file it against both: the
-- right patient, and the right encounter with that patient. An MRN alone puts
-- the result in the right folder but not on the right page.
--
-- WHY IT LIVES HERE AND NOT IN OPENELIS
-- Results are already correlated back by ORDER, not by patient lookup:
--
--   DiagnosticReport -> basedOn -> ServiceRequest -> order number
--                    -> his.lab_orders row -> patient_id (and now visit_number)
--
-- lab-order.model.ts takes patient_id from the local order row, never from the
-- message OpenELIS sends. So the visit does not have to survive a round trip
-- through the laboratory in order to be known when the result arrives — the
-- order remembers it.
--
-- That is deliberate, not incidental. OpenELIS drops ServiceRequest.encounter on
-- import (the handling is commented out in FhirApiWorkFlowServiceImpl), so a
-- visit sent that way would be silently lost. And we have already seen what
-- depending on the LIS to echo an identifier back costs: the requester is
-- transmitted correctly and then lost at the point of use. Filing a result
-- against the right encounter is not a good thing to bet on that behaviour.
--
-- WHY IT IS NULLABLE
-- Orders placed before this column existed had no visit, and inventing one would
-- be worse than admitting we do not have it — a backfilled guess is
-- indistinguishable from a recorded fact once it is in the column. The same
-- reasoning as ordering_provider_id in 008.
--
-- WHY IT IS ACCEPTED FROM THE REQUEST BODY
-- Unlike ordering_provider, which 008 moved to the token because it is an
-- identity claim the caller must not make, the visit is context the calling HIS
-- legitimately knows and we do not: the doctor is working inside a visit, and
-- nothing in this service's session tells us which one. It is data about the
-- encounter, not an assertion about who the caller is.
-- =============================================================================

SET search_path TO his;

ALTER TABLE his.lab_orders
    ADD COLUMN IF NOT EXISTS visit_number varchar(64);

COMMENT ON COLUMN his.lab_orders.visit_number IS
    'Encounter identifier from the calling HIS. Never sent to or read back from '
    'OpenELIS; results are filed against it via order correlation.';

-- Supports "every result from this visit", which is the question a clinician
-- opening an encounter actually asks.
CREATE INDEX IF NOT EXISTS ix_lab_orders_visit
    ON his.lab_orders (visit_number, created_at DESC)
 WHERE visit_number IS NOT NULL;

GRANT SELECT, INSERT, UPDATE ON his.lab_orders TO his_app;
