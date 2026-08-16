-- =============================================================================
-- Bridge service schema
-- Separate database from the HIS sandbox: the bridge owns its own integration
-- state and neither the HIS service nor OpenELIS reads it.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS bridge AUTHORIZATION bridge_app;
SET search_path TO bridge;

-- --- Outbound FHIR store ----------------------------------------------------
-- Resources the bridge PUBLISHES for OpenELIS to poll. This table backs the
-- read/search side of the bridge's FHIR R4 endpoint.
CREATE TABLE fhir_resources (
    resource_type varchar(64)  NOT NULL,
    resource_id   varchar(64)  NOT NULL,
    version_id    integer      NOT NULL DEFAULT 1,
    content       jsonb        NOT NULL,
    last_updated  timestamptz  NOT NULL DEFAULT now(),
    PRIMARY KEY (resource_type, resource_id)
);

-- Serves GET /fhir/Task?status=requested&owner=...
CREATE INDEX ix_fhir_task_status_owner ON fhir_resources (
    (content ->> 'status'),
    (content -> 'owner' ->> 'reference')
) WHERE resource_type = 'Task';

-- --- Order tracking ---------------------------------------------------------
-- One row per HIS lab order the bridge has taken responsibility for.
CREATE TABLE order_tracking (
    order_id            uuid PRIMARY KEY,
    order_number        varchar(60) NOT NULL UNIQUE,
    patient_id          uuid        NOT NULL,
    test_code           varchar(64) NOT NULL,
    loinc_code          varchar(32) NOT NULL,
    fhir_task_id        varchar(64) NOT NULL,
    fhir_servicerequest_id varchar(64) NOT NULL,
    fhir_patient_id     varchar(64) NOT NULL,
    fhir_specimen_id    varchar(64),
    task_status         varchar(32) NOT NULL,  -- requested|accepted|rejected|completed
    attempts            integer     NOT NULL DEFAULT 0,
    last_error          text,
    correlation_id      varchar(64),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_order_tracking_task ON order_tracking (fhir_task_id);
CREATE INDEX ix_order_tracking_sr ON order_tracking (fhir_servicerequest_id);

-- --- Inbound mirror ---------------------------------------------------------
-- Resources RECEIVED from OpenELIS (rest-hook subscription deliveries and the
-- periodic data-export bundle). Kept because correlating a DiagnosticReport to
-- a HIS order needs the ServiceRequest chain, which may arrive in any order.
CREATE TABLE received_resources (
    resource_type varchar(64) NOT NULL,
    resource_id   varchar(64) NOT NULL,
    content       jsonb       NOT NULL,
    received_at   timestamptz NOT NULL DEFAULT now(),
    processed     boolean     NOT NULL DEFAULT false,
    PRIMARY KEY (resource_type, resource_id)
);

CREATE INDEX ix_received_unprocessed ON received_resources (resource_type, received_at)
    WHERE processed = false;

-- --- Idempotency ------------------------------------------------------------
-- Guards against duplicate Kafka delivery and replayed result messages.
CREATE TABLE processed_events (
    event_key    varchar(200) PRIMARY KEY,
    event_type   varchar(64)  NOT NULL,
    processed_at timestamptz  NOT NULL DEFAULT now()
);

-- --- Released results the bridge has already forwarded ----------------------
CREATE TABLE forwarded_results (
    openelis_result_ref varchar(128) PRIMARY KEY,
    order_id            uuid        NOT NULL,
    forwarded_at        timestamptz NOT NULL DEFAULT now()
);

-- --- Dead letters -----------------------------------------------------------
CREATE TABLE dead_letters (
    id             bigserial PRIMARY KEY,
    source         varchar(64) NOT NULL,   -- kafka topic or fhir endpoint
    reason         text        NOT NULL,
    payload        jsonb,
    correlation_id varchar(64),
    created_at     timestamptz NOT NULL DEFAULT now()
);

GRANT USAGE ON SCHEMA bridge TO bridge_app;
GRANT ALL ON ALL TABLES IN SCHEMA bridge TO bridge_app;
GRANT ALL ON ALL SEQUENCES IN SCHEMA bridge TO bridge_app;
