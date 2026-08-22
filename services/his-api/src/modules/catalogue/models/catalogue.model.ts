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
   * Matched on loinc_code so a test already known keeps its established
   * test_code and the orders referencing it stay intact. A newly discovered
   * test has no local code to preserve, so it takes its LOINC: unfamiliar to
   * read, but stable and unambiguous, which is what a key needs to be.
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
           VALUES ($1, $2, $1, $3, NULL, $4, true, 'DISCOVERED', now())
           ON CONFLICT (loinc_code) DO UPDATE SET
               test_name     = excluded.test_name,
               specimen_type = excluded.specimen_type,
               result_unit   = coalesce(excluded.result_unit, his.test_catalogue.result_unit),
               is_active     = true,
               source        = 'DISCOVERED',
               synced_at     = now()
           WHERE his.test_catalogue.source <> 'LOCAL'`,
          [test.loinc, test.name, test.specimenName, test.resultUnit ?? null],
        );
        upserted += result.rowCount ?? 0;
      }

      // Withdrawn tests are DEACTIVATED, never deleted: historical orders
      // reference them, and an order from last year must still say what it was
      // for. LOCAL rows are left alone.
      const deactivated = await client.query(
        `UPDATE his.test_catalogue
            SET is_active = false, synced_at = now()
          WHERE source = 'DISCOVERED'
            AND is_active
            AND loinc_code <> ALL ($1)`,
        [tests.map((test) => test.loinc)],
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
