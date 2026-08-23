-- =============================================================================
-- Security audit trail
--
-- NOT the same thing as his.lab_order_events, and the difference is the whole
-- reason this table exists. That one records what happened to an ORDER. This
-- one records who touched a PATIENT'S DATA — including the reads, which leave
-- no other trace at all, and including the attempts that were refused.
--
-- Shaped as FHIR AuditEvent (R4), which is the current spelling of RFC 3881 /
-- DICOM Supplement 95, the schema IHE ATNA asks for.
--
-- WHY IT LIVES IN THIS DATABASE
-- An audit trail must not be droppable: an access that was not recorded must
-- not have happened. Taken naively that trades availability for compliance —
-- but not if the row is written to the database the request already depends on,
-- in the same transaction. Anything that stops the audit write already stops
-- the request, so there is no new failure mode. Shipping to a central Audit
-- Record Repository is then a separate relay that can lag but cannot lose.
-- =============================================================================

SET search_path TO his;

CREATE TABLE IF NOT EXISTS audit_events (
    audit_id     bigserial PRIMARY KEY,

    -- WHEN. Always UTC: records from services whose clocks disagree cannot be
    -- ordered, and an audit trail that cannot be ordered is hard to rely on.
    recorded_at  timestamptz NOT NULL DEFAULT now(),

    -- WHAT. `action` is the FHIR code: C reate, R ead, U pdate, D elete,
    -- E xecute. `event_type` is ours, and is what a human searches on.
    event_type   varchar(64)  NOT NULL,
    action       char(1)      NOT NULL CHECK (action IN ('C','R','U','D','E')),

    -- WHETHER IT WORKED. FHIR AuditEvent.outcome: 0 success, 4 minor failure,
    -- 8 serious failure. Refusals are the rows an investigation starts from, so
    -- they are recorded exactly like successes.
    outcome      char(1)      NOT NULL DEFAULT '0' CHECK (outcome IN ('0','4','8')),
    outcome_desc text,

    -- WHO. usr_id from the verified token, never from the request body. Null
    -- only when the request was refused before an identity was established —
    -- which is itself worth recording.
    actor_id     varchar(64),
    actor_name   varchar(128),
    actor_ip     inet,

    -- WHERE FROM. The service that observed it, so one repository can hold the
    -- whole estate.
    source       varchar(64)  NOT NULL,

    -- ON WHAT. A FHIR-style reference: Patient/<id>, ServiceRequest/<id>.
    -- Deliberately a reference and NOT the data: this table records THAT a
    -- record was read, never its contents. Otherwise it becomes a second copy
    -- of the patient database, kept longer and guarded less.
    entity_ref   varchar(128),
    entity_type  varchar(32),

    -- Ties an audit row to the request it came from, and so to the application
    -- logs for the same request.
    correlation_id varchar(64),

    -- Set by the relay once the row has reached the central repository. Null
    -- means "not yet shipped", and the relay claims rows the same way the
    -- outbox does.
    shipped_at   timestamptz
);

-- The three questions this table is actually asked, in order of frequency:
--   "everything user X did"          "everything done to patient Y"
--   "everything that failed"
CREATE INDEX IF NOT EXISTS ix_audit_actor  ON audit_events (actor_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_entity ON audit_events (entity_ref, recorded_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_failed ON audit_events (recorded_at DESC)
    WHERE outcome <> '0';

CREATE INDEX IF NOT EXISTS ix_audit_unshipped ON audit_events (audit_id)
    WHERE shipped_at IS NULL;

-- Append-only, enforced rather than agreed.
--
-- An audit trail whose subjects can edit it is not evidence. The application
-- role may INSERT and SELECT; it may not UPDATE or DELETE. The one exception is
-- the shipped_at column, which the relay has to set — granted narrowly rather
-- than by granting UPDATE on the table.
--
-- This is a floor, not a ceiling: it stops the application, not a database
-- superuser. Real tamper-evidence needs the repository to be somewhere the
-- audited estate cannot write at all.
-- Note the asymmetry with every other table here, which is granted ALL. The
-- application may add rows and read them back, and that is the whole list.
GRANT SELECT, INSERT ON his.audit_events TO his_app;
GRANT USAGE, SELECT ON SEQUENCE his.audit_events_audit_id_seq TO his_app;

-- The one exception: the relay marks a row shipped. Column-scoped, so it can
-- record that a row left without being able to change what the row says.
GRANT UPDATE (shipped_at) ON his.audit_events TO his_app;

COMMENT ON TABLE audit_events IS
    'IHE ATNA security audit trail: who accessed which patient data, when, and '
    'whether it succeeded. Append-only. Retained for years, never swept by the '
    'operational retention windows.';
