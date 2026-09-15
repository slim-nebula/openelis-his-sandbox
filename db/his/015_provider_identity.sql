-- =============================================================================
-- The clinician the LABORATORY is told about, which is not the account that
-- signed in.
--
-- IN THE REAL HIS
-- HIS-org-setup-service holds mlh_his_hcp_health_care_provider — the clinician
-- as a clinical entity, one row per practitioner:
--
--     id              Int    @id @default(autoincrement())
--     usr_id          Int?                                  <- NULLABLE
--     license_number  String?
--     name, name_ar
--
-- 008 made this service key an order on the token's usr_id, which was right at
-- the time and is the wrong thing to send onward. usr_id identifies an ACCOUNT.
-- hcp.id identifies a PERSON who is accountable for a test. Three properties of
-- that schema make the difference concrete:
--
--   * usr_id is nullable. A visiting consultant, a referring physician, anyone
--     whose account has not been created or has been disabled, exists as a
--     provider with no login. Key on usr_id and those clinicians have no
--     identity to send at all.
--
--   * usr_id carries no unique constraint. Nothing stops two provider rows
--     sharing one. A key that can collide is not a key.
--
--   * the rest of the clinical record already uses hcp.id —
--     mlh_his_sys_patient_locations.ih_hcp_hcp_id names the attending doctor
--     that way. Sending usr_id would leave the laboratory's idea of "which
--     doctor" unable to line up with the HIS's own.
--
-- THIS DOES NOT WEAKEN THE TOKEN RULE
-- The ordering clinician is still decided by the verified token and never by
-- the request body (008). The token says WHICH ACCOUNT; the provider row is the
-- correct name for the person behind it. Nothing is accepted from the caller.
--
--     verified token -> usr_id -> provider row -> hcp.id -> FHIR Practitioner
--
-- SO BOTH COLUMNS STAY, BECAUSE THEY ANSWER DIFFERENT QUESTIONS
--     ordering_provider_id      which ACCOUNT placed this order   (audit)
--     ordering_provider_hcp_id  which CLINICIAN is accountable    (the report)
--
-- An investigation asks the first. A laboratory asks the second. Collapsing
-- them into one column is what made this wrong in the first place.
--
-- WHAT THE SANDBOX DOES INSTEAD, AND WHY IT LOOKS LIKE THIS
-- There is no provider table here. Adding one would be modelling YOUR system
-- inside a sandbox that exists to show you an integration, and it would go
-- stale the first time org-setup-service changed. The token carries hcp_id and
-- hcp_license directly, standing in for the lookup a real deployment does
-- against mlh_his_hcp_health_care_provider.
--
-- The licence is stored on the ORDER here for the same reason, and that is a
-- sandbox artefact you should not copy: a licence number is an attribute of a
-- practitioner, not of an order, and belongs on the provider row you join at
-- dispatch. It is here only because there is nothing to join to.
--
-- Both nullable, and no backfill. Orders placed before this existed had no
-- provider identity recorded, and inventing one would be indistinguishable from
-- a verified fact once it is in the column. They publish no requester at all —
-- which the laboratory handles, and which `make requester` §6 proves.
-- =============================================================================

SET search_path TO his;

ALTER TABLE his.lab_orders
    ADD COLUMN IF NOT EXISTS ordering_provider_hcp_id  varchar(64),
    ADD COLUMN IF NOT EXISTS ordering_provider_license varchar(64);

COMMENT ON COLUMN his.lab_orders.ordering_provider_hcp_id IS
    'The ordering clinician as a CLINICAL identity — mlh_his_hcp_health_care_provider.id '
    'in the real HIS, resolved from the verified token''s usr_id. This is what the '
    'laboratory is told, and what the FHIR Practitioner id is derived from. '
    'NULL when the signed-in user has no provider row, e.g. a receptionist.';

COMMENT ON COLUMN his.lab_orders.ordering_provider_license IS
    'The clinician''s licence number, sent to the laboratory as a second identifier '
    'because a laboratory recognises a licence where an internal id means nothing. '
    'SANDBOX ARTEFACT: in the real HIS this is joined from the provider row at '
    'dispatch, not copied onto every order.';

-- "What has this clinician ordered" is asked of the clinical identity now, not
-- of the account, and reporting will follow the same move.
CREATE INDEX IF NOT EXISTS ix_lab_orders_provider_hcp_id
    ON his.lab_orders (ordering_provider_hcp_id);

GRANT SELECT, INSERT, UPDATE ON his.lab_orders TO his_app;
