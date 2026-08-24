-- =============================================================================
-- Who ordered the test, according to something other than a text box.
--
-- WHAT WAS WRONG
-- ordering_provider was a string the caller typed. The API has authenticated
-- every request since the auth work, so the service knew exactly who was
-- calling — and recorded whatever came up in the payload instead. That left two
-- different answers to "who ordered this test" in one database:
--
--   his.audit_events.actor_id   'user 12'      <- from the verified token
--   his.lab_orders.ordering_provider  'Dr. Konate'   <- from an input box
--
-- with nothing reconciling them. Every audit row is only as good as that field.
--
-- It travelled, too. The bridge derived the FHIR Practitioner identity from a
-- hash of the name string, so 'Dr. Konate', 'Dr. Konaté' and 'dr konate' became
-- three different clinicians in the laboratory's own provider records.
--
-- And clinically it is the field that matters most: the ordering provider is who
-- receives the result, who is telephoned about a critical value, and who is
-- accountable for acting on it. A prefilled text box means an order is
-- attributed to whoever the form happened to suggest.
--
-- WHAT THIS ADDS
-- ordering_provider_id: the usr_id from the token. Stable, and unlike a name it
-- does not change when somebody's accent is typed differently.
--
-- ordering_provider stays, because a laboratory report has to print a human
-- name, but it is now written from the token's usr_full_name rather than from
-- the request body.
--
-- Historical rows keep a NULL id. They were placed before the API could know,
-- and inventing an identity for them would be worse than admitting we do not
-- have one — a backfilled guess is indistinguishable from a verified fact once
-- it is in the column.
-- =============================================================================

SET search_path TO his;

ALTER TABLE his.lab_orders
    ADD COLUMN IF NOT EXISTS ordering_provider_id varchar(64);

COMMENT ON COLUMN his.lab_orders.ordering_provider_id IS
    'usr_id of the authenticated user who placed the order, from the token. '
    'NULL only for orders placed before identity was recorded.';

COMMENT ON COLUMN his.lab_orders.ordering_provider IS
    'Display name of the ordering clinician, taken from the token''s '
    'usr_full_name. Never accepted from the request body.';

-- Reporting asks "what has this clinician ordered" far more often than it asks
-- anything about the name.
CREATE INDEX IF NOT EXISTS ix_lab_orders_provider_id
    ON his.lab_orders (ordering_provider_id);

GRANT SELECT, INSERT, UPDATE ON his.lab_orders TO his_app;
