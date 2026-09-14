import { query } from '@config/db.js';

/**
 * Which results have already gone downstream.
 *
 * Keyed on (reference, VERSION), and the version is not decoration. OpenELIS
 * corrects a result by updating the same DiagnosticReport and incrementing
 * meta.versionId, so keying on the reference alone would make a correction look
 * like a duplicate and drop it — leaving the HIS showing a superseded value
 * while the laboratory believed it had issued the correction. Keying on both
 * still suppresses genuine at-least-once redelivery, which is what the guard is
 * for.
 */
export class ForwardedResultModel {
  /** Claims one version for forwarding; false when that exact version already went. */
  async claim(openelisResultRef: string, versionId: string, orderId: string): Promise<boolean> {
    const rows = await query(
      `INSERT INTO bridge.forwarded_results (openelis_result_ref, version_id, order_id)
       VALUES ($1, $2, $3)
       ON CONFLICT (openelis_result_ref, version_id) DO NOTHING
       RETURNING openelis_result_ref`,
      [openelisResultRef, versionId, orderId],
    );
    return rows.length > 0;
  }
}
