-- =============================================================================
-- HIS sandbox schema
-- Owned exclusively by the Patient + Lab Order microservice.
-- OpenELIS has no credentials for, and no route to, this database.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS his AUTHORIZATION his_app;
SET search_path TO his;

-- --- Patients ---------------------------------------------------------------
-- The HIS sandbox is the system of record for patient demographics.
CREATE TABLE patients (
    patient_id          uuid PRIMARY KEY,
    external_patient_id varchar(64)  NOT NULL UNIQUE,   -- MRN shown to clinicians
    first_name          varchar(100) NOT NULL,
    last_name           varchar(100) NOT NULL,
    sex                 char(1)      NOT NULL CHECK (sex IN ('M', 'F', 'U')),
    date_of_birth       date         NOT NULL,
    phone               varchar(40),
    national_id         varchar(64),
    created_at          timestamptz  NOT NULL DEFAULT now(),
    updated_at          timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX ix_patients_last_name ON patients (lower(last_name));
CREATE INDEX ix_patients_national_id ON patients (national_id) WHERE national_id IS NOT NULL;

-- --- Test catalogue ---------------------------------------------------------
-- Maps the HIS-facing test code to the LOINC code OpenELIS matches on.
-- An order whose test_code is absent here is rejected before it reaches Kafka,
-- which is the "invalid test code mapping" negative path.
CREATE TABLE test_catalogue (
    test_code       varchar(64) PRIMARY KEY,
    test_name       varchar(255) NOT NULL,
    loinc_code      varchar(32)  NOT NULL,
    specimen_type   varchar(64)  NOT NULL,   -- free text, mirrors OpenELIS sample type
    specimen_snomed varchar(32),             -- SNOMED CT code for FHIR Specimen.type
    result_unit     varchar(32),
    is_active       boolean      NOT NULL DEFAULT true
);

-- --- Lab orders -------------------------------------------------------------
CREATE TABLE lab_orders (
    order_id          uuid PRIMARY KEY,
    order_number      varchar(60)  NOT NULL UNIQUE,  -- <= 60: OpenELIS truncates beyond
    patient_id        uuid         NOT NULL REFERENCES patients (patient_id),
    test_code         varchar(64)  NOT NULL REFERENCES test_catalogue (test_code),
    test_name         varchar(255) NOT NULL,
    order_status      varchar(32)  NOT NULL,
    ordering_provider varchar(128) NOT NULL,
    facility_code     varchar(64)  NOT NULL,
    priority          varchar(16)  NOT NULL DEFAULT 'routine',
    status_detail     text,
    correlation_id    varchar(64),
    created_at        timestamptz  NOT NULL DEFAULT now(),
    updated_at        timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT ck_lab_orders_status CHECK (order_status IN (
        'CREATED', 'SENT_TO_LIS', 'ACCEPTED_BY_LIS', 'REJECTED_BY_LIS',
        'RESULT_AVAILABLE', 'FAILED'))
);

CREATE INDEX ix_lab_orders_patient ON lab_orders (patient_id, created_at DESC);
CREATE INDEX ix_lab_orders_status ON lab_orders (order_status);

-- --- Order lifecycle audit --------------------------------------------------
CREATE TABLE lab_order_events (
    event_id       bigserial PRIMARY KEY,
    order_id       uuid        NOT NULL REFERENCES lab_orders (order_id),
    event_type     varchar(64) NOT NULL,
    detail         text,
    correlation_id varchar(64),
    payload        jsonb,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_lab_order_events_order ON lab_order_events (order_id, created_at);

-- --- Simplified released results -------------------------------------------
-- A clinician-facing projection only. OpenELIS stays the system of record for
-- the detailed result and the laboratory workflow that produced it;
-- openelis_result_ref is the mandatory back-reference to that record.
CREATE TABLE lab_results_summary (
    result_id           uuid PRIMARY KEY,
    order_id            uuid         NOT NULL REFERENCES lab_orders (order_id),
    patient_id          uuid         NOT NULL REFERENCES patients (patient_id),
    test_code           varchar(64)  NOT NULL,
    test_name           varchar(255) NOT NULL,
    result_value        varchar(255),
    result_unit         varchar(32),
    reference_range     varchar(64),
    interpretation      varchar(64),
    result_status       varchar(32)  NOT NULL,
    released_at         timestamptz  NOT NULL,
    openelis_result_ref varchar(128) NOT NULL,
    received_at         timestamptz  NOT NULL DEFAULT now(),
    -- Idempotent ingestion: a replayed lab.result.released message for the same
    -- OpenELIS record updates in place rather than inserting a duplicate.
    CONSTRAINT uq_lab_results_openelis_ref UNIQUE (openelis_result_ref)
);

CREATE INDEX ix_lab_results_order ON lab_results_summary (order_id);
CREATE INDEX ix_lab_results_patient ON lab_results_summary (patient_id, released_at DESC);

-- --- Identifier cross-references -------------------------------------------
-- HIS identifier <-> OpenELIS/FHIR identifier, so neither side has to guess how
-- the other names the same thing.
CREATE TABLE integration_mappings (
    mapping_id      bigserial PRIMARY KEY,
    his_entity_type varchar(32)  NOT NULL,   -- patient | lab_order | result
    his_id          varchar(64)  NOT NULL,
    external_system varchar(32)  NOT NULL,   -- openelis | fhir
    external_type   varchar(64)  NOT NULL,   -- Patient | ServiceRequest | Task | ...
    external_id     varchar(128) NOT NULL,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_integration_mappings
        UNIQUE (his_entity_type, his_id, external_system, external_type)
);

-- --- Seed test catalogue ----------------------------------------------------
-- LOINC codes here must match those stamped onto OpenELIS tests by
-- openelis/provision/01-loinc-mapping.sql. The two files are the single
-- integration contract for test identity.
INSERT INTO test_catalogue
    (test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit)
VALUES
    ('HGB',  'Haemoglobin',        '718-7',  'Whole Blood', '119297000', 'g/dL'),
    ('GLUC', 'Glucose',            '2345-7', 'Plasma',      '119361006', 'mg/dL'),
    ('CREA', 'Creatinine',         '2160-0', 'Serum',       '119364003', 'mg/dL'),
    ('ALT',  'Transaminases GPT',  '1742-6', 'Serum',       '119364003', 'U/L'),
    ('CHOL', 'Total Cholesterol',  '2093-3', 'Serum',       '119364003', 'mg/dL'),
    ('PLT',  'Platelet Count',     '777-3',  'Whole Blood', '119297000', '10*3/uL');

-- --- Demo patient -----------------------------------------------------------
INSERT INTO patients
    (patient_id, external_patient_id, first_name, last_name, sex, date_of_birth, phone, national_id)
VALUES
    ('11111111-1111-1111-1111-111111111111', 'MRN-000001',
     'Amina', 'Traore', 'F', '1988-04-17', '+22370000001', 'NID-000001');

GRANT USAGE ON SCHEMA his TO his_app;
GRANT ALL ON ALL TABLES IN SCHEMA his TO his_app;
GRANT ALL ON ALL SEQUENCES IN SCHEMA his TO his_app;
