-- =============================================================================
-- Schema comments — the HIS estate database
--
-- WHY THIS FILE EXISTS
--
-- The migrations in this directory are heavily commented: roughly 700 of their
-- 1,200 lines explain a decision rather than execute one. But a `--` comment
-- lives in a FILE. It never reaches the database, so it is invisible to
-- `\d+ his.lab_orders`, to DBeaver, pgAdmin and DataGrip, and to every diagram
-- tool that reads schema metadata. A developer meeting this schema in a GUI —
-- which is how most people meet a schema — saw column names and nothing else.
--
-- COMMENT ON puts the explanation IN the database, where the tools look.
--
-- The rule followed here: a comment must say something the column NAME does
-- not. `patient_id uuid` needs no help. `order_number` does, because the fact
-- that it and not order_id is the integration's public key is the single most
-- important thing to know about this schema.
--
-- COMMENT ON is idempotent — it replaces — so this file is safe to re-run.
-- =============================================================================

SET search_path TO his;

-- --- patients ----------------------------------------------------------------
COMMENT ON TABLE  his.patients IS
    'People. Identity here is what the laboratory will file a specimen under, so '
    'a correction made after an order has been sent does NOT reach OpenELIS — it '
    'freezes a patient on first import. See docs/archive/upstream-issues/07.';
COMMENT ON COLUMN his.patients.patient_id IS
    'Internal surrogate key. Never leaves the estate: the integration keys on mrn '
    'and national_id, which a human can read back off a specimen tube.';
COMMENT ON COLUMN his.patients.mrn IS
    'Medical Record Number — the hospital-facing identifier, generated from a '
    'sequence. This is what staff quote to each other, so it travels to OpenELIS.';
COMMENT ON COLUMN his.patients.first_name IS
    'Given name. MUST NOT contain digits: OpenELIS validates person names and '
    'rejects them, and the rejection is silent from our side — the order retries '
    'for ever with no error anywhere. Placeholder names for unidentified patients '
    '("Unknown 47", "Baby of Ward 3") are the realistic way this happens.';
COMMENT ON COLUMN his.patients.last_name IS
    'Family name. Same digit restriction as first_name, and the same silent '
    'failure if it is broken.';
COMMENT ON COLUMN his.patients.sex IS
    'M, F or U. Single character because it is mapped to a FHIR AdministrativeGender '
    'code on the way out, not displayed as typed.';
COMMENT ON COLUMN his.patients.date_of_birth IS
    'Used by the laboratory to sanity-check reference ranges, so it is sent even '
    'though the order itself does not need it.';
COMMENT ON COLUMN his.patients.national_id IS
    'National identifier. The strongest cross-system match available, and what '
    'de-duplicates a patient the laboratory has seen before.';
COMMENT ON COLUMN his.patients.phone IS 'Contact number. Not sent to the laboratory.';
COMMENT ON COLUMN his.patients.created_at IS 'When the record was first written.';
COMMENT ON COLUMN his.patients.updated_at IS 'Last demographic change in the HIS — NOT the last change the laboratory saw.';

-- --- lab_orders --------------------------------------------------------------
COMMENT ON TABLE  his.lab_orders IS
    'One row per test requested. The lifecycle is CREATED -> SENT_TO_LIS -> '
    'ACCEPTED_BY_LIS -> RESULT_AVAILABLE, with REJECTED_BY_LIS and FAILED as '
    'terminal branches; an inpatient order starts at AWAITING_COLLECTION instead '
    'and has NO outbox row until a nurse records the draw.';
COMMENT ON COLUMN his.lab_orders.order_id IS
    'Internal surrogate key. Deliberately NOT the integration key — see order_number.';
COMMENT ON COLUMN his.lab_orders.order_number IS
    'THE integration key, and the one identifier a human can read off a form. It '
    'is what OpenELIS stores as electronic_order.external_id, what the result '
    'comes back keyed on, and what every runbook query starts from. Format '
    'LAB-YYYYMMDD-XXXXXXXX.';
COMMENT ON COLUMN his.lab_orders.patient_id IS 'The patient this specimen belongs to.';
COMMENT ON COLUMN his.lab_orders.test_code IS
    'The catalogue key, shaped "LOINC|Specimen" (e.g. 10351-5|Plasma). The specimen '
    'is part of the key because one LOINC code can be offered on several specimens '
    'and they are different orderable things — sending the code alone lets OpenELIS '
    'bind the first test that matches, which sends the specimen to the wrong bench.';
COMMENT ON COLUMN his.lab_orders.test_name IS
    'Human label at the time of ordering. Denormalised on purpose: the catalogue '
    'changes, and a result printed next year must still say what was ordered.';
COMMENT ON COLUMN his.lab_orders.order_status IS
    'CREATED, AWAITING_COLLECTION, SENT_TO_LIS, ACCEPTED_BY_LIS, REJECTED_BY_LIS, '
    'RESULT_AVAILABLE, FAILED. SENT_TO_LIS -> RESULT_AVAILABLE directly means the '
    'laboratory resulted an order it never acknowledged; see docs/durability.md.';
COMMENT ON COLUMN his.lab_orders.status_detail IS
    'Why the status is what it is — carries the laboratory''s rejection reason '
    'verbatim. Shown to the clinician, so it must never be a guess.';
COMMENT ON COLUMN his.lab_orders.ordering_provider IS
    'The clinician''s NAME, taken from the verified token at creation and never '
    'editable afterwards. Nobody may type a clinician name onto an order.';
COMMENT ON COLUMN his.lab_orders.ordering_provider_id IS
    'The clinician''s user id, captured from the token alongside the name.';
COMMENT ON COLUMN his.lab_orders.ordering_provider_hcp_id IS
    'Health-care-professional id. This — not the name — is what the laboratory '
    'reconciles a requester on, and what the FHIR Practitioner id is derived from.';
COMMENT ON COLUMN his.lab_orders.ordering_provider_license IS
    'Professional licence number, where the estate holds one. Shown to the '
    'laboratory so a human can verify who is entitled to order the test.';
COMMENT ON COLUMN his.lab_orders.facility_code IS
    'The referring site, joined to his.facilities. Reaches OpenELIS as an '
    'Organization so the laboratory knows where to send the report back to.';
COMMENT ON COLUMN his.lab_orders.priority IS 'routine | urgent | stat.';
COMMENT ON COLUMN his.lab_orders.patient_class IS
    'OUTPATIENT or INPATIENT, and it decides the WORKFLOW rather than just '
    'labelling it: an outpatient order dispatches at once because the laboratory '
    'draws the specimen; an inpatient order is held at AWAITING_COLLECTION until '
    'a nurse records the bedside draw.';
COMMENT ON COLUMN his.lab_orders.collected_at IS
    'When the specimen was drawn on the ward. Committed in the SAME transaction '
    'as the outbox row — a draw time without a dispatch strands the order, and a '
    'dispatch without a draw time loses the only reason it was waiting.';
COMMENT ON COLUMN his.lab_orders.visit_number IS
    'The encounter this order was placed during. What a result is filed against, '
    'so a patient with two admissions does not get one merged record.';
COMMENT ON COLUMN his.lab_orders.lab_progress IS
    'Where the order has reached INSIDE the laboratory — IN_LABORATORY, then '
    'AWAITING_VALIDATION. A second axis under ACCEPTED_BY_LIS, not a status: it '
    'only advances and never contradicts order_status.';
COMMENT ON COLUMN his.lab_orders.lab_progress_at IS 'When lab_progress last advanced.';
COMMENT ON COLUMN his.lab_orders.lab_accession IS
    'The laboratory''s own accession number. The number a technician will quote '
    'on the phone, which is why it is worth carrying back.';
COMMENT ON COLUMN his.lab_orders.correlation_id IS
    'Threads this order through every service, log line and Kafka message. The '
    'first thing to grep for when tracing one order across the estate.';
COMMENT ON COLUMN his.lab_orders.created_at IS 'When the clinician placed the order.';
COMMENT ON COLUMN his.lab_orders.updated_at IS 'Last status or progress change.';

-- --- lab_order_events --------------------------------------------------------
COMMENT ON TABLE  his.lab_order_events IS
    'Append-only history of one order. Nothing here is ever updated or deleted: '
    'it is the answer to "who did what, when" for an order somebody disputes.';
COMMENT ON COLUMN his.lab_order_events.event_id IS 'Sequence, and therefore the true order of events.';
COMMENT ON COLUMN his.lab_order_events.order_id IS 'The order this happened to.';
COMMENT ON COLUMN his.lab_order_events.event_type IS
    'ORDER_CREATED, SENT_TO_LIS, ACCEPTED_BY_LIS, REJECTED_BY_LIS, '
    'SPECIMEN_COLLECTED, RESULT_AVAILABLE, and the failure variants.';
COMMENT ON COLUMN his.lab_order_events.detail IS 'Human-readable note, including refusal reasons.';
COMMENT ON COLUMN his.lab_order_events.payload IS 'The event body as published, kept verbatim for replay and dispute.';
COMMENT ON COLUMN his.lab_order_events.correlation_id IS 'Ties this entry to the same trace as the order.';
COMMENT ON COLUMN his.lab_order_events.created_at IS 'When it happened.';

-- --- lab_results_summary -----------------------------------------------------
COMMENT ON TABLE  his.lab_results_summary IS
    'The report-level view of a released result: one row per DiagnosticReport. '
    'For a panel the flat value columns carry the FIRST analyte only — the whole '
    'panel is in lab_result_components. A copy, never the source of truth: '
    'openelis_result_ref always points back at the laboratory record.';
COMMENT ON COLUMN his.lab_results_summary.result_id IS 'Surrogate key.';
COMMENT ON COLUMN his.lab_results_summary.order_id IS 'The order this answers.';
COMMENT ON COLUMN his.lab_results_summary.patient_id IS 'Denormalised so a patient timeline needs no join through orders.';
COMMENT ON COLUMN his.lab_results_summary.test_code IS 'The catalogue key as ordered.';
COMMENT ON COLUMN his.lab_results_summary.test_name IS 'The laboratory''s name for the report — for a panel, the panel name.';
COMMENT ON COLUMN his.lab_results_summary.result_value IS
    'The first analyte''s value, kept as TEXT. Not numeric: a laboratory reports '
    '"<0.01", "Not detected" and "5.40" as values, and 5.40 is not 5.4 — the '
    'trailing zero states the precision of the measurement.';
COMMENT ON COLUMN his.lab_results_summary.result_unit IS 'Unit for result_value.';
COMMENT ON COLUMN his.lab_results_summary.reference_range IS 'Normal range as the laboratory formatted it, e.g. 3.9-5.8.';
COMMENT ON COLUMN his.lab_results_summary.interpretation IS 'The laboratory''s wording — "Normal", "High", "Critically abnormal".';
COMMENT ON COLUMN his.lab_results_summary.interpretation_code IS
    'The CODE beside the wording (H, L, A, HH, LL, AA). Carried separately so a '
    'consumer can tell critically abnormal from merely abnormal WITHOUT '
    'pattern-matching on the laboratory''s prose.';
COMMENT ON COLUMN his.lab_results_summary.result_status IS
    'final, amended, corrected or entered-in-error. entered-in-error is a '
    'RETRACTION: the value columns are nulled and the result must stop being '
    'shown, not merely be annotated.';
COMMENT ON COLUMN his.lab_results_summary.released_at IS 'When the laboratory validated and released it.';
COMMENT ON COLUMN his.lab_results_summary.lab_collected_at IS
    'When the specimen was actually drawn, as the LABORATORY recorded it. Read '
    'off the Specimen, not off Observation.effective — OpenELIS sets effective to '
    'the release time, which is plausible, hours wrong, and fails silently.';
COMMENT ON COLUMN his.lab_results_summary.openelis_result_ref IS
    'DiagnosticReport/{id} in OpenELIS. The mandatory back-reference to the record '
    'that remains the source of truth, and the idempotency key for redelivery.';
COMMENT ON COLUMN his.lab_results_summary.received_at IS 'When the HIS stored it — later than released_at by the transport delay.';

-- --- lab_result_components ---------------------------------------------------
COMMENT ON TABLE  his.lab_result_components IS
    'One row per ANALYTE — the whole panel, in the order the laboratory released '
    'it. Exists because a full blood count is eight numbers and an earlier version '
    'stored element zero and dropped the other seven with nothing recording the loss.';
COMMENT ON COLUMN his.lab_result_components.component_id IS 'Surrogate key.';
COMMENT ON COLUMN his.lab_result_components.result_id IS 'The report this analyte belongs to.';
COMMENT ON COLUMN his.lab_result_components.analyte_code IS 'LOINC code for this single measurement.';
COMMENT ON COLUMN his.lab_result_components.analyte_name IS 'What this component measures, e.g. "Haemoglobin".';
COMMENT ON COLUMN his.lab_result_components.result_value IS 'The measured value, as text, for the same reason as the summary column.';
COMMENT ON COLUMN his.lab_result_components.result_unit IS 'Unit for this analyte.';
COMMENT ON COLUMN his.lab_result_components.reference_range IS 'Normal range for this analyte.';
COMMENT ON COLUMN his.lab_result_components.interpretation IS 'The laboratory''s wording for this analyte.';
COMMENT ON COLUMN his.lab_result_components.interpretation_code IS 'The abnormal-flag code for this analyte.';
COMMENT ON COLUMN his.lab_result_components.position IS
    'Zero-based position within the report, preserving the laboratory''s own '
    'ordering. A panel has a conventional reading order and re-sorting it '
    'alphabetically makes a familiar report unreadable.';
COMMENT ON COLUMN his.lab_result_components.created_at IS 'When this component was stored.';

-- --- test_catalogue ----------------------------------------------------------
COMMENT ON TABLE  his.test_catalogue IS
    'What a doctor may order — a MIRROR of what OpenELIS offers, refreshed by '
    '`make sync-catalogue`. The laboratory owns its menu; this side never invents '
    'a test. A test missing here is a test the laboratory could not offer '
    'unambiguously, which is a mapping problem for the laboratory to fix.';
COMMENT ON COLUMN his.test_catalogue.test_code IS 'Primary key, shaped "LOINC|Specimen" — see lab_orders.test_code.';
COMMENT ON COLUMN his.test_catalogue.test_name IS
    'Display name. Qualified with the specimen when one LOINC runs on several, so '
    'the doctor''s search box shows what actually distinguishes them.';
COMMENT ON COLUMN his.test_catalogue.loinc_code IS 'The LOINC code alone. NOT unique here — it is unique only with the specimen.';
COMMENT ON COLUMN his.test_catalogue.specimen_type IS 'Specimen as the laboratory names it, e.g. "Whole Blood", "Plasma", "DBS".';
COMMENT ON COLUMN his.test_catalogue.specimen_snomed IS 'SNOMED code for the specimen, where the laboratory publishes one.';
COMMENT ON COLUMN his.test_catalogue.result_unit IS 'Expected unit, for display before a result exists.';
COMMENT ON COLUMN his.test_catalogue.is_active IS 'False withdraws a test from the menu without deleting history that references it.';
COMMENT ON COLUMN his.test_catalogue.source IS
    'DISCOVERED means read from OpenELIS and trustworthy. SEED means a local '
    'fixture — orderable, but not proof the laboratory accepts it.';
COMMENT ON COLUMN his.test_catalogue.synced_at IS 'Last refresh from OpenELIS. Staleness here is what CatalogueStale alerts on.';

-- --- facilities --------------------------------------------------------------
COMMENT ON TABLE  his.facilities IS
    'Referring sites — clinics, wards, departments. Reaches OpenELIS as a FHIR '
    'Organization so the laboratory can route the report back to where the order '
    'came from.';
COMMENT ON COLUMN his.facilities.facility_code IS
    'Primary key, and the stable identity. The NAME may be corrected; the code '
    'must not, because OpenELIS derives the Organization id from it.';
COMMENT ON COLUMN his.facilities.facility_name IS 'Display name, shown to laboratory staff.';
COMMENT ON COLUMN his.facilities.facility_type IS 'CLINIC, WARD, DEPARTMENT — for grouping and reporting.';
COMMENT ON COLUMN his.facilities.is_active IS 'False hides it from new orders without breaking existing ones.';
COMMENT ON COLUMN his.facilities.created_at IS 'When the site was registered.';

-- --- lab_billing_map ---------------------------------------------------------
COMMENT ON TABLE  his.lab_billing_map IS
    'Joins a laboratory test to what the HIS charges and claims for it. '
    'DELIBERATELY minimal: it is the foundation, and the business rules on top of '
    'it — when to charge, panel unbundling, reflex tests, inpatient routing — are '
    'the implementing team''s to decide. See docs/billing-integration.md.';
COMMENT ON COLUMN his.lab_billing_map.loinc_code IS 'Half the key. With specimen_type it matches test_catalogue.test_code.';
COMMENT ON COLUMN his.lab_billing_map.specimen_type IS
    'The other half. Present because the same analyte on a different specimen is '
    'a different amount of work, and may be a different charge.';
COMMENT ON COLUMN his.lab_billing_map.is_active IS 'False retires a mapping without deleting the history that priced against it.';
COMMENT ON COLUMN his.lab_billing_map.notes IS 'Free text for whoever maintains the mapping — why this code, who approved it.';
COMMENT ON COLUMN his.lab_billing_map.created_at IS 'When the mapping was added.';
COMMENT ON COLUMN his.lab_billing_map.updated_at IS 'When it last changed.';

-- --- outbox ------------------------------------------------------------------
COMMENT ON TABLE  his.outbox IS
    'The transactional outbox. An order and the event announcing it commit '
    'TOGETHER, so there is no window where the HIS has an order nobody will hear '
    'about, or an event for an order that rolled back. The relay drains this to '
    'Kafka and marks published_at only after the broker acknowledges — which is '
    'why a broker outage delays an order and can never lose one.';
COMMENT ON COLUMN his.outbox.outbox_id IS 'Sequence. The relay sends in this order and STOPS at the first failure, so per-order ordering holds.';
COMMENT ON COLUMN his.outbox.event_id IS 'Idempotency key. A redelivered event carrying this id is recognised and ignored downstream.';
COMMENT ON COLUMN his.outbox.aggregate_type IS 'What kind of thing changed — "LabOrder".';
COMMENT ON COLUMN his.outbox.aggregate_id IS 'Which one.';
COMMENT ON COLUMN his.outbox.topic IS 'Destination Kafka topic.';
COMMENT ON COLUMN his.outbox.partition_key IS
    'Kafka partition key — the ORDER NUMBER, so every event about one order lands '
    'on one partition and cannot be reordered relative to its siblings.';
COMMENT ON COLUMN his.outbox.payload IS 'The message body, exactly as it will be published.';
COMMENT ON COLUMN his.outbox.correlation_id IS 'Carried into the Kafka header so the trace survives the hop.';
COMMENT ON COLUMN his.outbox.created_at IS 'When the event was queued — the same instant the order committed.';
COMMENT ON COLUMN his.outbox.published_at IS
    'NULL means still owed to the broker. A growing count of NULLs is the signal '
    'that Kafka is unreachable or the relay has stopped.';
COMMENT ON COLUMN his.outbox.attempts IS 'Publish attempts. Climbing without published_at means the broker keeps refusing.';
COMMENT ON COLUMN his.outbox.last_error IS 'Why the last attempt failed.';

-- --- audit_events ------------------------------------------------------------
COMMENT ON TABLE  his.audit_events IS
    'Security and access audit trail, shaped for ATNA/IHE so it can be shipped to '
    'a hospital SIEM without remapping. Append-only.';
COMMENT ON COLUMN his.audit_events.audit_id IS 'Sequence.';
COMMENT ON COLUMN his.audit_events.recorded_at IS 'When the event happened.';
COMMENT ON COLUMN his.audit_events.event_type IS 'LOGIN, LOGOUT, ORDER_CREATE, RESULT_VIEW, and so on.';
COMMENT ON COLUMN his.audit_events.action IS 'ATNA action code: C reate, R ead, U pdate, D elete, E xecute.';
COMMENT ON COLUMN his.audit_events.outcome IS 'ATNA outcome: 0 success, 4 minor failure, 8 serious, 12 major.';
COMMENT ON COLUMN his.audit_events.outcome_desc IS 'Why it failed, when it did.';
COMMENT ON COLUMN his.audit_events.actor_id IS 'Who did it — the user id from the verified token, never a client-supplied value.';
COMMENT ON COLUMN his.audit_events.actor_name IS 'Their name at the time, denormalised so the trail survives a renamed user.';
COMMENT ON COLUMN his.audit_events.actor_ip IS 'Where from. inet, not text, so subnet queries work during an investigation.';
COMMENT ON COLUMN his.audit_events.source IS 'Which service recorded it.';
COMMENT ON COLUMN his.audit_events.entity_ref IS 'What was acted on — an order number, a patient id.';
COMMENT ON COLUMN his.audit_events.entity_type IS 'What kind of thing that reference names.';
COMMENT ON COLUMN his.audit_events.correlation_id IS 'Ties the audit entry to the request that caused it.';
COMMENT ON COLUMN his.audit_events.shipped_at IS 'When it was forwarded to the log topic. NULL means not yet shipped.';

-- --- integration_mappings ----------------------------------------------------
COMMENT ON TABLE  his.integration_mappings IS
    'Generic "our id <-> their id" table for external systems. Kept deliberately '
    'open-ended: the OpenELIS integration does not need it, because FHIR resource '
    'ids are DERIVED from HIS ids rather than stored, but a second external system '
    'that issues its own identifiers would.';
COMMENT ON COLUMN his.integration_mappings.mapping_id IS 'Surrogate key.';
COMMENT ON COLUMN his.integration_mappings.his_entity_type IS 'What kind of thing on our side — Patient, LabOrder.';
COMMENT ON COLUMN his.integration_mappings.his_id IS 'Our identifier for it.';
COMMENT ON COLUMN his.integration_mappings.external_system IS 'Which foreign system issued the other id.';
COMMENT ON COLUMN his.integration_mappings.external_type IS 'What they call that kind of thing.';
COMMENT ON COLUMN his.integration_mappings.external_id IS 'Their identifier.';
COMMENT ON COLUMN his.integration_mappings.created_at IS 'When the mapping was recorded.';
