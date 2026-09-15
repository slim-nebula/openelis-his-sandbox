-- =============================================================================
-- Which FHIR Practitioner is which HIS clinician.
--
-- WHY THIS EXISTS WHEN THE UUID IS ALREADY DERIVED FROM THE USER ID
-- The bridge mints Practitioner ids deterministically —
-- DeterministicGuid("provider-id|<usr_id>") — so the mapping is, today,
-- computable rather than stored. That works, and it is why this table did not
-- exist. It is also the wrong thing to depend on, for a reason the FHIR
-- specification is explicit about:
--
--   "Logical Ids are always opaque, and external systems need not and should
--    not attempt to determine their internal structure."
--
-- A logical id belongs to the server that assigns it. Nothing obliges any FHIR
-- server to preserve ours across versioning, a conditional update, or a resource
-- recreated after a purge — and the moment one does not, a correlation scheme
-- that reads meaning out of the id has no fallback and no record of what it
-- used to mean. Business identity belongs in Resource.identifier, which is why
-- the Practitioner also carries the user id under
-- http://his-sandbox.local/user.
--
-- So this changes nothing about behaviour and everything about what the
-- behaviour RESTS ON. The derivation stays, because OpenELIS pulls these
-- resources and calls UUID.fromString() on the ids it imports — it cannot search
-- by identifier on that leg, so we must supply a real UUID before it has ever
-- seen the clinician, and conditional create/update is not available to us
-- there. What stops is treating the id's CONTENT as the source of truth.
--
-- Two things follow immediately:
--   * reverse lookup (Practitioner UUID -> HIS user) becomes a query rather
--     than an impossibility; hashing is one-way.
--   * if the derivation is ever replaced with server-assigned ids, or with an
--     mCSD Health Worker Registry issuing canonical practitioner identities,
--     the mapping already exists and the identifier system URI carries over
--     unchanged.
--
-- WHY NOT his.integration_mappings
-- That table has the right shape, but it lives in the HIS database and the
-- bridge has no credentials for it. The bridge is what mints the Practitioner,
-- so the record belongs beside order_tracking, which already maps HIS orders to
-- the FHIR resources published for them.
-- =============================================================================

SET search_path TO bridge;

CREATE TABLE IF NOT EXISTS bridge.practitioner_identities (
    his_user_id          varchar(64)  PRIMARY KEY,
    fhir_practitioner_id varchar(64)  NOT NULL UNIQUE,
    -- The name as it was at the time. Kept for humans reading this table, never
    -- for matching: a name is a spelling and this is a correlation record.
    display_name         varchar(255),
    first_seen           timestamptz  NOT NULL DEFAULT now(),
    last_seen            timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE bridge.practitioner_identities IS
    'HIS clinician (usr_id) to FHIR Practitioner logical id. Explicit rather '
    'than derived, so nothing depends on reading meaning out of an id the FHIR '
    'specification says is opaque.';
COMMENT ON COLUMN bridge.practitioner_identities.display_name IS
    'Informational only. Never a matching key — the same clinician may be '
    'spelled several ways and must still be one practitioner.';

-- Reverse lookup: given a Practitioner seen on a resource, which clinician is
-- it? This is the direction hashing cannot go.
CREATE INDEX IF NOT EXISTS ix_practitioner_identities_fhir
    ON bridge.practitioner_identities (fhir_practitioner_id);

GRANT SELECT, INSERT, UPDATE ON bridge.practitioner_identities TO bridge_app;
