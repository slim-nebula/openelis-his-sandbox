-- =============================================================================
-- Schema comments — the bridge database
--
-- Companion to db/his/018_schema_comments.sql; the reasoning for putting these
-- in the database rather than leaving them as `--` comments is written there.
--
-- This schema is the integration's MEMORY. Nothing clinical is decided here:
-- every table is either something published for OpenELIS to collect, a mirror
-- of something OpenELIS pushed back, or a record of an attempt. That is worth
-- knowing before reading any single table — several of them look like
-- duplicates of HIS tables and are not.
--
-- Neither the HIS service nor OpenELIS holds credentials for this database.
--
-- COMMENT ON is idempotent, so this file is safe to re-run.
-- =============================================================================

SET search_path TO bridge;

-- --- fhir_resources ----------------------------------------------------------
COMMENT ON TABLE  bridge.fhir_resources IS
    'What the bridge PUBLISHES for OpenELIS to poll — Task, ServiceRequest, '
    'Patient, Specimen, Practitioner, Organization. This is the queue: an order '
    'accepted by the HIS but not yet collected exists here and nowhere else on '
    'this side, which is why a bridge restart cannot lose it.';
COMMENT ON COLUMN bridge.fhir_resources.resource_type IS 'FHIR resource type. Half the primary key.';
COMMENT ON COLUMN bridge.fhir_resources.resource_id IS
    'The resource id — a DETERMINISTIC RFC 4122 v5 UUID derived from the HIS id '
    '(SHA-1, DNS namespace, names like "task|{orderId}"). Deterministic so a '
    'replayed event produces an UPDATE to the same resource rather than a second '
    'order, and so a clinician never becomes a duplicate Practitioner.';
COMMENT ON COLUMN bridge.fhir_resources.version_id IS 'Bumped on every write. What FHIR clients read as meta.versionId.';
COMMENT ON COLUMN bridge.fhir_resources.content IS
    'The resource itself. Written and served as TEXT, never round-tripped through '
    'a JavaScript object: JS has one number type, so parsing and re-serialising '
    'turns the laboratory''s 1.10 into 1.1 and silently reports a different '
    'precision than the analyser produced.';
COMMENT ON COLUMN bridge.fhir_resources.last_updated IS
    'Last write. The oldest last_updated among Tasks still `requested` is what '
    'the OrderUndelivered alert measures.';

-- --- order_tracking ----------------------------------------------------------
COMMENT ON TABLE  bridge.order_tracking IS
    'The bridge''s own view of an order: which HIS order maps to which FHIR '
    'resources, and how far it has got. NOT a copy of his.lab_orders — it holds '
    'the correlation keys that let a result found in OpenELIS be walked back to '
    'the order that caused it.';
COMMENT ON COLUMN bridge.order_tracking.order_id IS 'The HIS order id.';
COMMENT ON COLUMN bridge.order_tracking.order_number IS 'The human-readable order number, and the last-resort correlation route.';
COMMENT ON COLUMN bridge.order_tracking.patient_id IS 'The HIS patient id.';
COMMENT ON COLUMN bridge.order_tracking.test_code IS 'The catalogue key as ordered, "LOINC|Specimen".';
COMMENT ON COLUMN bridge.order_tracking.loinc_code IS 'The LOINC alone — what OpenELIS actually binds a test on.';
COMMENT ON COLUMN bridge.order_tracking.fhir_task_id IS 'The published Task. This is what OpenELIS collects and should acknowledge.';
COMMENT ON COLUMN bridge.order_tracking.fhir_servicerequest_id IS
    'The published ServiceRequest. The anchor of the correlation chain: a returned '
    'DiagnosticReport points at a per-analysis ServiceRequest which points back here.';
COMMENT ON COLUMN bridge.order_tracking.fhir_patient_id IS 'The published Patient.';
COMMENT ON COLUMN bridge.order_tracking.fhir_specimen_id IS 'The published Specimen. NULL when none was sent.';
COMMENT ON COLUMN bridge.order_tracking.task_status IS
    'requested (awaiting collection), accepted or rejected (the laboratory''s '
    'verdict), or completed. `completed` means a RESULT came back while the Task '
    'was still unacknowledged — the laboratory evidently did the work, so the '
    'result closes the Task and stops it being re-offered for ever.';
COMMENT ON COLUMN bridge.order_tracking.attempts IS 'Times the bridge tried to build and publish this order.';
COMMENT ON COLUMN bridge.order_tracking.last_error IS 'Why the last attempt failed.';
COMMENT ON COLUMN bridge.order_tracking.correlation_id IS 'The trace id inherited from the HIS event.';
COMMENT ON COLUMN bridge.order_tracking.created_at IS 'When the bridge published this order. The basis of the reconciliation ledger''s day buckets.';
COMMENT ON COLUMN bridge.order_tracking.updated_at IS 'Last status change.';

-- --- delivery_leases ---------------------------------------------------------
COMMENT ON TABLE  bridge.delivery_leases IS
    'One row per Task handed to the laboratory. Withholds it from later polls '
    'until the lease expires, so two simultaneous polls cannot import one order '
    'twice. It is a CLOCK, not a process: a bridge restart mid-import neither '
    'strands the Task nor duplicates it, because expiry is the only thing that '
    'releases it.';
COMMENT ON COLUMN bridge.delivery_leases.resource_id IS 'The Task under lease.';
COMMENT ON COLUMN bridge.delivery_leases.leased_until IS
    'Held until this moment (BRIDGE_TASK_LEASE_SECONDS, default 90). Releasing is '
    'an UPDATE that moves this into the past — never a DELETE, which would throw '
    'away the delivery count on exactly the orders that worked.';
COMMENT ON COLUMN bridge.delivery_leases.first_at IS 'First time this Task was handed over.';
COMMENT ON COLUMN bridge.delivery_leases.last_at IS 'Most recent hand-over.';

-- --- received_resources ------------------------------------------------------
COMMENT ON TABLE  bridge.received_resources IS
    'A mirror of everything OpenELIS PUSHES back. Written the instant it arrives '
    'and correlated later on a timer — which is why a bridge restart mid-'
    'correlation loses nothing, and why resources arriving out of order (a report '
    'before its Observations, routinely) are simply picked up by a later sweep.';
COMMENT ON COLUMN bridge.received_resources.resource_type IS 'DiagnosticReport, Observation, ServiceRequest, Specimen, Patient, Task.';
COMMENT ON COLUMN bridge.received_resources.resource_id IS 'OpenELIS''s id for it.';
COMMENT ON COLUMN bridge.received_resources.content IS
    'The resource as received, verbatim. RESULTS live here, so anything reading '
    'this column must go through the text path — see fhir_resources.content.';
COMMENT ON COLUMN bridge.received_resources.received_at IS
    'When it arrived. Also the clock for patience: a report that cannot be '
    'correlated is retried until this is older than the correlation window, then '
    'dead-lettered rather than retried for ever.';
COMMENT ON COLUMN bridge.received_resources.processed IS
    'True once acted on. FALSE IS LOAD-BEARING FOR RETENTION: an unprocessed row '
    'is a result that has not reached a patient record yet, and its age is no '
    'evidence it never will — so the sweep deletes processed rows only.';

-- --- forwarded_results -------------------------------------------------------
COMMENT ON TABLE  bridge.forwarded_results IS
    'What has already been sent to the HIS, so a redelivered report is not '
    'published twice. Keyed on report AND version, because a correction is a new '
    'version of the same report and MUST get through.';
COMMENT ON COLUMN bridge.forwarded_results.openelis_result_ref IS 'DiagnosticReport/{id} — the laboratory''s record.';
COMMENT ON COLUMN bridge.forwarded_results.version_id IS
    'OpenELIS''s meta.versionId, bumped when a result is corrected. Part of the '
    'key, so the correction is not mistaken for a duplicate of the original.';
COMMENT ON COLUMN bridge.forwarded_results.order_id IS 'The HIS order this result answers.';
COMMENT ON COLUMN bridge.forwarded_results.forwarded_at IS 'When it was published to the HIS.';

-- --- processed_events --------------------------------------------------------
COMMENT ON TABLE  bridge.processed_events IS
    'Claimed event keys. Kafka delivery is at-least-once, so the same order event '
    'can arrive twice; claiming the key makes the second one a no-op. The claim is '
    'RELEASED if processing then fails, so a genuine retry is not swallowed as a '
    'duplicate.';
COMMENT ON COLUMN bridge.processed_events.event_key IS 'The event id, or topic:partition:offset when the producer sent none.';
COMMENT ON COLUMN bridge.processed_events.event_type IS 'Which kind of event this key belongs to.';
COMMENT ON COLUMN bridge.processed_events.processed_at IS 'When it was claimed.';

-- --- dead_letters ------------------------------------------------------------
COMMENT ON TABLE  bridge.dead_letters IS
    'Failures that need a HUMAN. Nothing retries out of here — a row is a decision '
    'somebody has to make. `make dead-letters` reads it; DeadLettersGrowing alerts '
    'on it.';
COMMENT ON COLUMN bridge.dead_letters.id IS 'Sequence.';
COMMENT ON COLUMN bridge.dead_letters.source IS 'Where it came from — a Kafka topic, or "fhir:DiagnosticReport".';
COMMENT ON COLUMN bridge.dead_letters.reason IS
    'What went wrong, written for the person who will read it at 3am rather than '
    'for a log parser.';
COMMENT ON COLUMN bridge.dead_letters.payload IS 'The offending message, kept whole so it can be corrected and replayed.';
COMMENT ON COLUMN bridge.dead_letters.correlation_id IS 'The trace this failure belongs to.';
COMMENT ON COLUMN bridge.dead_letters.created_at IS 'When it failed.';

-- --- test_catalogue ----------------------------------------------------------
COMMENT ON TABLE  bridge.test_catalogue IS
    'What OpenELIS offers, as the bridge discovered it. The source the HIS mirror '
    'is built from, and what the order consumer checks a specimen against BEFORE '
    'sending — an order whose specimen cannot be resolved is refused here rather '
    'than bound to the wrong bench by the laboratory.';
COMMENT ON COLUMN bridge.test_catalogue.name IS 'Display name, qualified by specimen when one LOINC runs on several.';
COMMENT ON COLUMN bridge.test_catalogue.specimen_id IS 'OpenELIS''s internal sample-type id.';
COMMENT ON COLUMN bridge.test_catalogue.result_unit IS 'Expected unit, where the laboratory publishes one.';
COMMENT ON COLUMN bridge.test_catalogue.synced_at IS
    'Last discovery run. Its age is bridge_catalogue_age_seconds, which reports '
    '-1 rather than 0 when nothing has ever synced — for an AGE, zero is the '
    'healthiest possible reading and would hide the least healthy possible state.';

-- --- catalogue_syncs ---------------------------------------------------------
COMMENT ON TABLE  bridge.catalogue_syncs IS
    'History of catalogue refreshes, kept so a menu that changed can be explained '
    'afterwards. A test disappearing from the doctor''s list is alarming; this is '
    'where the answer is.';
COMMENT ON COLUMN bridge.catalogue_syncs.id IS 'Sequence.';
COMMENT ON COLUMN bridge.catalogue_syncs.started_at IS 'When the sync began.';
COMMENT ON COLUMN bridge.catalogue_syncs.finished_at IS 'When it ended. NULL means it did not.';
COMMENT ON COLUMN bridge.catalogue_syncs.status IS 'OK, FAILED, or REFUSED when the shrink guard blocked it.';
COMMENT ON COLUMN bridge.catalogue_syncs.tests_before IS 'Menu size before.';
COMMENT ON COLUMN bridge.catalogue_syncs.tests_after IS
    'Menu size after. A large drop is what the shrink guard refuses: a partial '
    'read of the laboratory''s menu would silently un-order half the hospital''s '
    'tests, and that must be a deliberate override (FORCE=true), not a default.';
COMMENT ON COLUMN bridge.catalogue_syncs.added IS 'Tests that appeared.';
COMMENT ON COLUMN bridge.catalogue_syncs.removed IS 'Tests that vanished — the column to read when a doctor says a test is missing.';
COMMENT ON COLUMN bridge.catalogue_syncs.changed IS 'Tests whose name, specimen or unit moved.';
COMMENT ON COLUMN bridge.catalogue_syncs.detail IS 'Free text, including why tests were withheld as ambiguous.';

-- --- export_status_checks ----------------------------------------------------
COMMENT ON TABLE  bridge.export_status_checks IS
    'Whether OpenELIS is still PUSHING results to us, asked periodically. Exists '
    'because a laboratory that has stopped delivering looks exactly like a '
    'laboratory with nothing ready — the bridge receives nothing either way, and '
    'the alternative detection mechanism is a clinician eventually asking where a '
    'result went.';
COMMENT ON COLUMN bridge.export_status_checks.id IS 'Sequence.';
COMMENT ON COLUMN bridge.export_status_checks.checked_at IS 'When we asked.';
COMMENT ON COLUMN bridge.export_status_checks.subscription_id IS 'OpenELIS''s id for the push subscription.';
COMMENT ON COLUMN bridge.export_status_checks.endpoint IS 'Where it pushes. Only the subscription pointing at us matters.';
COMMENT ON COLUMN bridge.export_status_checks.verdict IS
    'OK, STALE or FAILING — judged against the cadence OpenELIS says it INTENDS '
    'to keep, not against a threshold invented here, so the check stays correct '
    'if the laboratory changes its schedule.';
COMMENT ON COLUMN bridge.export_status_checks.last_status IS 'How OpenELIS reports its most recent attempt.';
COMMENT ON COLUMN bridge.export_status_checks.last_success IS
    'Last successful push. Load-bearing: OpenELIS re-sends everything since this '
    'moment, so a failed push WIDENS the next window instead of skipping it — '
    'which is why a bridge outage does not lose results.';
COMMENT ON COLUMN bridge.export_status_checks.last_attempt IS 'Last attempt, successful or not.';
COMMENT ON COLUMN bridge.export_status_checks.failed_last_24h IS 'Failures in the last day.';
COMMENT ON COLUMN bridge.export_status_checks.total_last_24h IS 'Attempts in the last day.';
COMMENT ON COLUMN bridge.export_status_checks.max_interval_minutes IS 'The cadence OpenELIS intends to keep — the basis for judging staleness.';
COMMENT ON COLUMN bridge.export_status_checks.detail IS 'The verdict in words.';
