import { query, type Row } from '@config/db.js';
import { logger } from '@config/logger.js';
import { toIso } from '@shared/utils/serialization.utils.js';

export interface IDeadLetter {
  id: number;
  source: string;
  reason: string;
  correlationId: string | null;
  createdAt: string | null;
}

/**
 * Failures that need a human.
 *
 * The dead-letter queue is the integration's honesty mechanism: anything the
 * bridge cannot deliver and cannot retry into success is written here with the
 * reason in plain words, rather than logged and forgotten. `make monitoring`
 * alerts on its growth, and `/ops/dead-letters` is how an operator reads it —
 * behind a token, because the rows name patients and the tests they were sent
 * for.
 *
 * Shared because both the order path and the result path write to it.
 */
export class DeadLetterModel {
  async record(
    source: string,
    reason: string,
    payload: string | null,
    correlationId: string | null,
  ): Promise<void> {
    await query(
      `INSERT INTO bridge.dead_letters (source, reason, payload, correlation_id)
       VALUES ($1, $2, $3::jsonb, $4)`,
      [source, reason, payload, correlationId],
    );
    logger.error(`Dead-lettered from ${source}: ${reason} (correlation ${correlationId})`);
  }

  async recent(): Promise<IDeadLetter[]> {
    const rows = await query<Row>(
      `SELECT id, source, reason, correlation_id, created_at
         FROM bridge.dead_letters ORDER BY created_at DESC LIMIT 100`,
    );
    return rows.map((row) => ({
      id: Number(row.id),
      source: String(row.source),
      reason: String(row.reason),
      correlationId: row.correlation_id === null ? null : String(row.correlation_id),
      createdAt: toIso(row.created_at),
    }));
  }
}
