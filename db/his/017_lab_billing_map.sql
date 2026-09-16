-- =============================================================================
-- What a laboratory test costs, and what the claim calls it.
--
-- WHAT THIS IS FOR
-- Billing happens in the HIS, never in the laboratory. OpenELIS knows what a
-- test IS (a LOINC code on a specimen); it knows nothing about money, payers or
-- claim codes, and it should not. This table is the join between the two: given
-- what the laboratory can perform, it says what the hospital charges for it and
-- what code the claim carries.
--
-- IT IS DELIBERATELY THIN. It holds identity and nothing else — no price, no
-- policy, no rules about when to charge. Those belong to the billing system and
-- to decisions this repository has no business making. See
-- docs/billing-integration.md for the four decisions it leaves open and why.
--
-- WHY THE KEY IS (loinc_code, specimen_type) AND NEVER loinc_code ALONE
-- This is the single most important line in the file. A LOINC code says what is
-- measured, not what it is measured in. 10351-5 is HIV viral load, and this
-- laboratory offers it on Serum, on Plasma and on dried blood spot — three
-- orderable things, three methods, and plausibly three prices. OpenELIS 3.2.2.0
-- resolves an incoming order by LOINC *and* specimen (OGC-1145), and
-- bridge.test_catalogue is keyed the same way for the same reason.
--
-- Key this on LOINC alone and one of those three rows wins arbitrarily. The
-- order is still accepted, the patient is still charged, the claim is still
-- submitted — for the wrong test, with nothing failing anywhere. That is the
-- failure this composite key exists to make impossible.
--
-- WHY A FOREIGN KEY INTO THE CATALOGUE
-- The catalogue is the laboratory's menu, mirrored from OpenELIS and never
-- authored here. The foreign key means a row cannot be written for a test the
-- laboratory does not offer — a mapping invented ahead of the menu, or left
-- behind after a test was withdrawn, is refused rather than quietly priced.
--
-- It also means the withdrawal path is honest: test_catalogue deactivates rather
-- than deletes, because orders reference it, so a withdrawn test keeps its
-- mapping and old orders keep resolving. `make billing-check` is what tells you
-- the mapping has gone stale; the constraint is what stops it being fiction.
--
-- HOW THIS MAPS ONTO THE REAL HIS
-- The sandbox has no billing system, so the two columns below are named for
-- what they mean rather than for the tables they point at. In the estate they
-- are foreign keys:
--
--   charge_item_ref  -> mlh_erp_fin_scm_main_items.id     (fn_str_mit_id)
--                       the chargeable ERP item, which carries retail_price,
--                       chargable and vat_percentage. This is what the patient
--                       is actually charged, and mlh_his_ehr_clinical_orders
--                       REQUIRES it for order_type = 1 (Laboratory).
--
--   claim_code       -> mlh_his_ehr_mdc_cpt_codes.code    (ep_mdc_cpt_code)
--                       the CPT code, 5 characters, which classifies the
--                       procedure for the claim. Optional in the estate's own
--                       schema, and optional here for the same reason: a
--                       cash-paying patient needs a price, not a claim code.
--
-- WHY THE PRICE IS NOT IN THIS TABLE
-- Because it is not in the estate either. Billing prices from the ERP item; the
-- OrderCreatedEvent patient-service already publishes carries mit_id and not the
-- CPT code. Copying a price here would create a second answer to "what does this
-- cost", and the two would drift the first time someone repriced. One place.
-- =============================================================================

CREATE TABLE IF NOT EXISTS his.lab_billing_map (
    loinc_code      varchar(32)  NOT NULL,
    specimen_type   varchar(64)  NOT NULL,

    -- What the patient is charged for. NOT NULL because the estate's own
    -- validator refuses a Laboratory order without one:
    --   requiresItemId = [1, 2, 3, 4, 9, 10]  →  fn_str_mit_id is required
    -- The database agreeing with the validator is the point; a nullable column
    -- here would let a row exist that can never produce a billable order.
    charge_item_ref varchar(64)  NOT NULL,

    -- What the claim calls it. Nullable, matching ep_mdc_cpt_code in the
    -- estate: not every order is claimed against a payer.
    claim_code      varchar(16),

    -- Withdrawn mappings are deactivated, never deleted: orders already placed
    -- reference what they were charged under, and an audit needs to resolve it.
    is_active       boolean      NOT NULL DEFAULT true,

    notes           text,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT lab_billing_map_pkey PRIMARY KEY (loinc_code, specimen_type),

    CONSTRAINT lab_billing_map_catalogue_fkey
        FOREIGN KEY (loinc_code, specimen_type)
        REFERENCES his.test_catalogue (loinc_code, specimen_type),

    -- A charge reference of '' is the shape of a half-finished deployment, and
    -- it would satisfy NOT NULL. It must not.
    CONSTRAINT lab_billing_map_charge_item_not_blank
        CHECK (length(btrim(charge_item_ref)) > 0),

    -- CPT is five characters. The check is deliberately loose about WHICH five
    -- — Category III codes end in T, PLA codes in U — because tightening it to
    -- five digits would refuse valid codes, and a billing map that refuses a
    -- valid code is worse than one that accepts an invalid one a human can see.
    CONSTRAINT lab_billing_map_claim_code_shape
        CHECK (claim_code IS NULL OR claim_code ~ '^[A-Za-z0-9]{5}$')
);

COMMENT ON TABLE  his.lab_billing_map IS
    'Joins the laboratory''s menu to what the hospital charges and claims. Identity only — no price, no policy. See docs/billing-integration.md.';
COMMENT ON COLUMN his.lab_billing_map.charge_item_ref IS
    'The chargeable item. In the real HIS: mlh_erp_fin_scm_main_items.id, i.e. fn_str_mit_id on the clinical order.';
COMMENT ON COLUMN his.lab_billing_map.claim_code IS
    'The claim code. In the real HIS: mlh_his_ehr_mdc_cpt_codes.code, i.e. ep_mdc_cpt_code on the clinical order. Null when nothing is claimed.';

-- Reverse lookups: "what does this charge item cover", asked when an item is
-- repriced or retired, and "which tests carry this claim code", asked when a
-- payer queries a claim.
CREATE INDEX IF NOT EXISTS lab_billing_map_charge_item_idx
    ON his.lab_billing_map (charge_item_ref);
CREATE INDEX IF NOT EXISTS lab_billing_map_claim_code_idx
    ON his.lab_billing_map (claim_code) WHERE claim_code IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Demonstration rows.
--
-- These exist so `make billing-check` has something to report and so a developer
-- can see the shape. The references are obviously fake — ITEM-… and the 8xxxx
-- codes here are illustrative, not a mapping anybody should ship. Real values
-- come from the hospital's own ERP item master and its licensed CPT set.
--
-- Note there is no row for every test on purpose: an unmapped test is a normal
-- state during setup, and `make billing-check` is what makes it visible instead
-- of leaving it to be discovered by a failed charge.
-- -----------------------------------------------------------------------------
INSERT INTO his.lab_billing_map (loinc_code, specimen_type, charge_item_ref, claim_code, notes)
SELECT c.loinc_code, c.specimen_type,
       'ITEM-' || upper(replace(c.loinc_code, '-', '')) || '-' || upper(left(c.specimen_type, 3)),
       CASE c.loinc_code
           WHEN '10351-5' THEN '87536'   -- HIV-1 quantification, illustrative
           WHEN '11011-4' THEN '87522'   -- HCV quantification, illustrative
           WHEN '29615-2' THEN '87517'   -- HBV quantification, illustrative
           ELSE NULL
       END,
       'demonstration row — replace during deployment'
  FROM his.test_catalogue c
 WHERE c.is_active
   AND c.loinc_code IN ('10351-5', '11011-4', '29615-2')
ON CONFLICT (loinc_code, specimen_type) DO NOTHING;

-- his_app is the application role; migrations run as the owner.
GRANT ALL ON his.lab_billing_map TO his_app;
