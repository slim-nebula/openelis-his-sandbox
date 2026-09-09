-- =============================================================================
-- The individual analytes inside one report.
--
-- WHAT WAS WRONG
-- A DiagnosticReport may reference several Observations. A full blood count is
-- one report and eight analytes; an electrolyte panel is one report and four.
-- The bridge forwarded the FIRST Observation and dropped the rest, so a HIS
-- reading this projection saw one number where the laboratory had released
-- eight — with nothing anywhere indicating loss. Every test on the current menu
-- is single-analyte, which is why this never surfaced, and is also why it had to
-- be fixed BEFORE a panel is offered rather than after.
--
-- WHY A CHILD TABLE AND NOT MORE COLUMNS
-- The number of analytes is a property of the test, not of the schema. Widening
-- lab_results_summary would mean choosing a maximum, and the first panel that
-- exceeded it would truncate silently — the same class of failure this migration
-- exists to end.
--
-- WHY lab_results_summary KEEPS ITS FLAT COLUMNS
-- They are not redundant and they are not deprecated. They hold the REPORT-level
-- answer: the value a single-analyte result carries, and for a panel, the first
-- component, so that every existing consumer, query and test assertion keeps
-- working unchanged. A caller that knows nothing about panels still gets a
-- sensible answer; a caller that reads `components` gets the whole report.
--
-- WHY THE UNIQUE KEY ON THE PARENT IS UNTOUCHED
-- lab_results_summary is upserted on openelis_result_ref, and that is what makes
-- a correction land on the row it corrects instead of inserting a second one.
-- Components hang off the parent and are REPLACED wholesale on each upsert: a
-- corrected report is a new statement about every analyte in it, not a patch to
-- some of them. Merging component-by-component would leave an analyte the
-- laboratory withdrew still showing.
--
-- ORDERING
-- `position` preserves the order the laboratory released them in. A haemogram
-- read out of order is harder to read and, for a differential count, actively
-- misleading. It is part of the unique key because a report may legitimately
-- carry the same analyte code twice (the same measurement at two times), and
-- keying on the code alone would silently discard the second.
-- =============================================================================

SET search_path TO his;

CREATE TABLE IF NOT EXISTS his.lab_result_components (
    component_id        uuid PRIMARY KEY,
    result_id           uuid         NOT NULL
                          REFERENCES his.lab_results_summary (result_id) ON DELETE CASCADE,
    -- The analyte's own code, from Observation.code. LOINC where the laboratory
    -- supplies one; whatever coding it used otherwise. Null when it sent none,
    -- which is legal and leaves analyte_name the only identification.
    analyte_code        varchar(64),
    analyte_name        varchar(255) NOT NULL,
    result_value        varchar(255),
    result_unit         varchar(32),
    reference_range     varchar(64),
    interpretation      varchar(64),
    -- Per-analyte severity. A panel's components do not share one: a metabolic
    -- panel can be normal in six analytes and critically high in the seventh,
    -- and that seventh is the entire clinical point of the report.
    interpretation_code varchar(16),
    position            integer      NOT NULL,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_lab_result_components UNIQUE (result_id, analyte_code, position)
);

-- The only access path: every component of one report, in released order.
CREATE INDEX IF NOT EXISTS ix_lab_result_components_result
    ON his.lab_result_components (result_id, position);

COMMENT ON TABLE his.lab_result_components IS
    'One row per analyte within a released report. A single-analyte result has '
    'one row whose values equal the parent''s flat columns; a panel has one row '
    'per component. Replaced wholesale when the report is corrected.';

COMMENT ON COLUMN his.lab_result_components.position IS
    'Order the laboratory released the analytes in, zero-based. Part of the '
    'unique key because one report may legitimately repeat an analyte code.';

GRANT SELECT, INSERT, UPDATE, DELETE ON his.lab_result_components TO his_app;
