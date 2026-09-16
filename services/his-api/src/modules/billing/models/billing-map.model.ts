import { query, type Row } from '@config/db.js';

/**
 * What a laboratory test is charged and claimed as.
 *
 * The whole point of this module is that there is ONE place that answers
 * "what does this test cost and what is it called on the claim". Everything
 * about *when* to charge, *whether* to charge, and how a panel is handled is
 * deliberately absent — those are business decisions, and they are listed as
 * such in docs/billing-integration.md.
 *
 * In the real HIS the two references below are foreign keys:
 *   chargeItemRef -> mlh_erp_fin_scm_main_items.id  (fn_str_mit_id)
 *   claimCode     -> mlh_his_ehr_mdc_cpt_codes.code (ep_mdc_cpt_code)
 */
export interface IBillingMapping {
  loincCode: string;
  specimenType: string;
  /** The chargeable item. Never null: a Laboratory order cannot be billed without one. */
  chargeItemRef: string;
  /** The claim code. Null is legitimate — not every order is claimed against a payer. */
  claimCode: string | null;
  isActive: boolean;
  notes: string | null;
}

/** One unmapped, orderable test. What `make billing-check` reports. */
export interface IUnmappedTest {
  testCode: string;
  testName: string;
  loincCode: string;
  specimenType: string;
}

/** One mapping whose test the laboratory no longer offers. */
export interface IOrphanedMapping {
  loincCode: string;
  specimenType: string;
  chargeItemRef: string;
  reason: 'test withdrawn' | 'mapping deactivated';
}

const toMapping = (row: Row): IBillingMapping => ({
  loincCode: String(row.loinc_code),
  specimenType: String(row.specimen_type),
  chargeItemRef: String(row.charge_item_ref),
  claimCode: row.claim_code === null || row.claim_code === undefined ? null : String(row.claim_code),
  isActive: Boolean(row.is_active),
  notes: row.notes === null || row.notes === undefined ? null : String(row.notes),
});

export class BillingMapModel {
  /**
   * THE RESOLVER. One function, so there is one place to change when the
   * estate's own tables replace these columns.
   *
   * Keyed on (loinc, specimen) and never on loinc alone. 10351-5 is HIV viral
   * load on serum, on plasma and on dried blood spot — three orderable things
   * that may carry three prices. Resolving on the LOINC would return one of
   * them arbitrarily, charge for it, and claim for it, with nothing failing.
   *
   * Returns null rather than throwing: an unmapped test is a normal state
   * during setup, and it is the CALLER's business decision whether that blocks
   * the order, places it unbilled, or queues it for review. Deciding here would
   * be this module making a policy choice it has no standing to make.
   */
  async resolve(loincCode: string, specimenType: string): Promise<IBillingMapping | null> {
    const rows = await query<Row>(
      `SELECT loinc_code, specimen_type, charge_item_ref, claim_code, is_active, notes
         FROM his.lab_billing_map
        WHERE loinc_code = $1 AND specimen_type = $2 AND is_active`,
      [loincCode, specimenType],
    );
    const row = rows[0];
    return row ? toMapping(row) : null;
  }

  /** Resolve by the catalogue's own test code, which is what an order carries. */
  async resolveByTestCode(testCode: string): Promise<IBillingMapping | null> {
    // Joined rather than split on `|`: test_code is opaque, and locally seeded
    // single-specimen tests keep a bare code with no separator at all.
    const rows = await query<Row>(
      `SELECT m.loinc_code, m.specimen_type, m.charge_item_ref, m.claim_code, m.is_active, m.notes
         FROM his.test_catalogue c
         JOIN his.lab_billing_map m
           ON m.loinc_code = c.loinc_code AND m.specimen_type = c.specimen_type
        WHERE c.test_code = $1 AND m.is_active`,
      [testCode],
    );
    const row = rows[0];
    return row ? toMapping(row) : null;
  }

  async list(): Promise<IBillingMapping[]> {
    const rows = await query<Row>(
      `SELECT loinc_code, specimen_type, charge_item_ref, claim_code, is_active, notes
         FROM his.lab_billing_map ORDER BY loinc_code, specimen_type`,
    );
    return rows.map(toMapping);
  }

  /**
   * Orderable today, and nobody can be charged for it.
   *
   * This is the half that matters most: a doctor can place the order, the
   * laboratory will run it, and the hospital has no way to bill it. Nothing
   * errors — the money is simply never collected.
   */
  async unmapped(): Promise<IUnmappedTest[]> {
    const rows = await query<Row>(
      `SELECT c.test_code, c.test_name, c.loinc_code, c.specimen_type
         FROM his.test_catalogue c
         LEFT JOIN his.lab_billing_map m
           ON m.loinc_code = c.loinc_code AND m.specimen_type = c.specimen_type AND m.is_active
        WHERE c.is_active AND m.loinc_code IS NULL
        ORDER BY c.test_name, c.specimen_type`,
    );
    return rows.map((r) => ({
      testCode: String(r.test_code),
      testName: String(r.test_name),
      loincCode: String(r.loinc_code),
      specimenType: String(r.specimen_type),
    }));
  }

  /**
   * Mapped, but the laboratory no longer offers it.
   *
   * Harmless on its own — no new order can reach it, because the ordering
   * screen reads the catalogue. It matters because it is the visible trace of a
   * test being withdrawn, and somebody should decide whether the charge item
   * retires with it.
   */
  async orphaned(): Promise<IOrphanedMapping[]> {
    const rows = await query<Row>(
      `SELECT m.loinc_code, m.specimen_type, m.charge_item_ref,
              CASE WHEN NOT m.is_active THEN 'mapping deactivated'
                   ELSE 'test withdrawn' END AS reason
         FROM his.lab_billing_map m
         JOIN his.test_catalogue c
           ON c.loinc_code = m.loinc_code AND c.specimen_type = m.specimen_type
        WHERE NOT c.is_active OR NOT m.is_active
        ORDER BY m.loinc_code, m.specimen_type`,
    );
    return rows.map((r) => ({
      loincCode: String(r.loinc_code),
      specimenType: String(r.specimen_type),
      chargeItemRef: String(r.charge_item_ref),
      reason: String(r.reason) as IOrphanedMapping['reason'],
    }));
  }

  /**
   * One charge item covering several tests is normal — a panel, or two
   * specimens the hospital prices the same. One charge item covering tests
   * that are clinically unrelated is usually a copy-paste error in the
   * deployment spreadsheet, and it charges patients for the wrong thing.
   *
   * Reported, never refused: only the hospital knows which of the two it is.
   */
  async sharedChargeItems(): Promise<{ chargeItemRef: string; tests: string[] }[]> {
    const rows = await query<Row>(
      `SELECT m.charge_item_ref,
              array_agg(m.loinc_code || ' [' || m.specimen_type || ']'
                        ORDER BY m.loinc_code, m.specimen_type) AS tests
         FROM his.lab_billing_map m
        WHERE m.is_active
        GROUP BY m.charge_item_ref
       HAVING count(*) > 1
        ORDER BY m.charge_item_ref`,
    );
    return rows.map((r) => ({
      chargeItemRef: String(r.charge_item_ref),
      tests: (r.tests as string[]) ?? [],
    }));
  }
}

export default BillingMapModel;
