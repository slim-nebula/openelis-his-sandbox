import { query, transaction, type Row } from '@config/db.js';
import type { DiscoveredTest } from '@shared/clients/bridge.client.js';

export interface ICatalogueEntry {
  testCode: string;
  testName: string;
  loincCode: string;
  specimenType: string;
  specimenSnomed: string | null;
  resultUnit: string | null;
}

export interface IMirrorOutcome {
  offered: number;
  upserted: number;
  deactivated: number;
  before: number;
}

export class CatalogueModel {
  async listActive(): Promise<ICatalogueEntry[]> {
    const rows = await query<Row>(
      `SELECT test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit
         FROM his.test_catalogue WHERE is_active ORDER BY test_name`,
    );
    return rows.map((row) => ({
      testCode: String(row.test_code),
      testName: String(row.test_name),
      loincCode: String(row.loinc_code),
      specimenType: String(row.specimen_type),
      specimenSnomed: row.specimen_snomed === null ? null : String(row.specimen_snomed),
      resultUnit: row.result_unit === null ? null : String(row.result_unit),
    }));
  }

  /**
   * Replaces the menu with what OpenELIS currently offers, in one transaction.
   *
   * Matched on (loinc_code, specimen_type) so a test already known keeps its
   * established test_code and the orders referencing it stay intact.
   *
   * The pair, not the code. A LOINC names what is measured, not what it is
   * measured in, and OpenELIS's catalogue carries several tests per code —
   * 10351-5 is HIV viral load on DBS, on plasma and on serum. Matching on the
   * code alone made those impossible to represent, and the sync withheld all
   * 17 of them from the doctor rather than pick one.
   *
   * A newly discovered row takes `<loinc>|<specimen>` as its test_code. That
   * keeps the property the LOINC alone used to provide — derived only from what
   * the laboratory told us, so it is identical on every sync and every
   * installation — and restores the uniqueness the bare code no longer has.
   */
  async mirror(tests: DiscoveredTest[]): Promise<IMirrorOutcome> {
    return transaction(async (client) => {
      const before = await client.query(
        `SELECT count(*)::int AS n FROM his.test_catalogue
          WHERE is_active AND source = 'DISCOVERED'`,
      );

      let upserted = 0;
      for (const test of tests) {
        const result = await client.query(
          `INSERT INTO his.test_catalogue
               (test_code, test_name, loinc_code, specimen_type, specimen_snomed,
                result_unit, is_active, source, synced_at)
           VALUES ($1, $3, $2, $4, NULL, $5, true, 'DISCOVERED', now())
           ON CONFLICT (loinc_code, specimen_type) DO UPDATE SET
               test_name     = excluded.test_name,
               result_unit   = coalesce(excluded.result_unit, his.test_catalogue.result_unit),
               is_active     = true,
               source        = 'DISCOVERED',
               synced_at     = now()
           WHERE his.test_catalogue.source <> 'LOCAL'`,
          [
            `${test.loinc}|${test.specimenName}`,
            test.loinc,
            test.name,
            test.specimenName,
            test.resultUnit ?? null,
          ],
        );
        upserted += result.rowCount ?? 0;
      }

      // Withdrawn tests are DEACTIVATED, never deleted: historical orders
      // reference them, and an order from last year must still say what it was
      // for. LOCAL rows are left alone.
      //
      // Compared on the PAIR, like the upsert above. Comparing on loinc_code
      // alone would keep a withdrawn specimen alive whenever a sibling sharing
      // its code survived — the laboratory drops HIV-on-serum, and the doctor
      // carries on ordering it because HIV-on-plasma is still offered.
      const deactivated = await client.query(
        `UPDATE his.test_catalogue
            SET is_active = false, synced_at = now()
          WHERE source = 'DISCOVERED'
            AND is_active
            AND (loinc_code || '|' || coalesce(specimen_type, '')) <> ALL ($1::text[])`,
        [tests.map((test) => `${test.loinc}|${test.specimenName}`)],
      );

      return {
        offered: tests.length,
        upserted,
        deactivated: deactivated.rowCount ?? 0,
        before: (before.rows[0] as Row).n as number,
      };
    });
  }
}
