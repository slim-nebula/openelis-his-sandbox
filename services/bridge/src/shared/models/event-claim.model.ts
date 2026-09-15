import { query } from '@config/db.js';

/**
 * At-least-once delivery made idempotent.
 *
 * Kafka redelivers on any failure that leaves an offset uncommitted, and the
 * bridge deliberately leaves offsets uncommitted so that failures retry. The
 * claim is what stops a retry becoming a SECOND order in the laboratory.
 *
 * Shared rather than owned by one module because both the order consumer and
 * the result correlator need exactly this, on the same table, with the same
 * semantics — and a claim table that two modules implemented separately would
 * be two tables' worth of subtly different behaviour over one.
 */
export class EventClaimModel {
  /**
   * Claims an event key, returning false if it was already claimed.
   *
   * INSERT ... ON CONFLICT DO NOTHING is the whole mechanism: it is one
   * statement, so two consumers racing on the same key cannot both win, and it
   * needs no transaction or advisory lock to say so.
   */
  async claim(eventKey: string, eventType: string): Promise<boolean> {
    const result = await query(
      `INSERT INTO bridge.processed_events (event_key, event_type)
       VALUES ($1, $2)
       ON CONFLICT (event_key) DO NOTHING
       RETURNING event_key`,
      [eventKey, eventType],
    );
    return result.length > 0;
  }

  /**
   * Gives the claim back after a failure, so redelivery genuinely retries
   * instead of being swallowed as a duplicate.
   *
   * Without this, one transient failure — the HIS being slow to start, say —
   * would mark the order permanently processed while nothing had been
   * published, and the order would never reach the laboratory.
   */
  async release(eventKey: string): Promise<void> {
    await query('DELETE FROM bridge.processed_events WHERE event_key = $1', [eventKey]);
  }
}
