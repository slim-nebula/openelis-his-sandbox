-- =============================================================================
-- Where the order came from.
--
-- WHAT THIS IS, AND WHAT IT IS NOT
-- This table is a SANDBOX STAND-IN. It exists so the concept is demonstrable,
-- not because a real HIS should copy it. See the note at the bottom for where
-- this belongs in yours.
--
-- WHY IT EXISTS AT ALL
-- lab_orders.facility_code was free text with a default nobody changed, and it
-- reached nothing: his-api put it on the payload, the bridge received it, and
-- OrderMapper never referenced it. Verified on the wire - FAC-001 appears in
-- none of the five resources we publish.
--
-- That was fine while nothing consumed it. It stopped being fine when the
-- laboratory's accessioning wizard turned out to REQUIRE a Referring Site,
-- which is precisely "where did this come from" - and which a technician now
-- types by hand on every single order because we send nothing.
--
-- WHY A TYPE COLUMN
-- Because the type is the part that varies and the part a laboratory acts on. A
-- clinic, a ward and an emergency department are different origins with
-- different turnaround expectations and different people to telephone. A flat
-- list of names loses that.
--
-- WHY CODES ARE STABLE
-- facility_code is the join to OpenELIS: the laboratory creates one Organization
-- per site with organization.code set to this value, and the bridge maps
-- code -> fhir_uuid. Renaming a facility is safe; renumbering one is not.
--
-- ---------------------------------------------------------------------------
-- IN YOUR REAL HIS, DO NOT BUILD THIS TABLE
--
-- The referring site is already somewhere in your estate, and copying it here
-- would create a second place for it to drift:
--
--   * If modules/visits records WHERE the patient is - ward, unit, clinic on
--     the encounter - that is your referring site, and it comes off the VISIT
--     rather than off a field on the order. A patient moves between wards; the
--     order should say where they were when it was placed.
--
--   * If you only know the hospital, use business_unit_id from the IAM token.
--     Coarser, but it already exists, is already maintained, and is already on
--     every request.
--
-- Either way what the bridge needs is unchanged: a stable code per site that
-- the laboratory can mirror onto an Organization.
-- =============================================================================

SET search_path TO his;

CREATE TABLE IF NOT EXISTS facilities (
    facility_code varchar(64) PRIMARY KEY,
    facility_name varchar(255) NOT NULL,
    -- CLINIC, WARD, EMERGENCY, OUTPATIENT. Deliberately not a foreign key to a
    -- lookup table: this is a stand-in, and a second table would imply the
    -- shape is prescriptive when it is illustrative.
    facility_type varchar(32)  NOT NULL,
    is_active     boolean      NOT NULL DEFAULT true,
    created_at    timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE his.facilities IS
    'Sandbox stand-in for the calling HIS''s own site list. In a real HIS the '
    'referring site comes from the visit (where the patient is) or from '
    'business_unit_id on the token - not from a table like this.';

-- A spread of types rather than four clinics, so the distinction the laboratory
-- cares about is visible in the demo.
INSERT INTO facilities (facility_code, facility_name, facility_type) VALUES
    ('FAC-001', 'Obygaine Clinic',      'CLINIC'),
    ('FAC-002', 'Emergency Department', 'EMERGENCY'),
    ('FAC-003', 'Medical Ward',         'WARD'),
    ('FAC-004', 'Outpatient Clinic',    'OUTPATIENT')
ON CONFLICT (facility_code) DO NOTHING;

-- The picker's query: active sites, in a stable order.
CREATE INDEX IF NOT EXISTS ix_facilities_active
    ON his.facilities (facility_name)
 WHERE is_active;

-- NOT a foreign key from lab_orders.facility_code.
--
-- Orders placed before this table existed carry codes with no row here, and a
-- constraint would either reject them retrospectively or demand invented
-- backfill. The API validates on the way IN, which stops new bad data without
-- rewriting history - the same reasoning as ordering_provider_id in 008.
GRANT SELECT ON his.facilities TO his_app;
