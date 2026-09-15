import { pool } from '@config/db.js';
import { eventPublisher } from '@config/kafka.js';
import { logger } from '@config/logger.js';
import type { Row } from '@config/db.js';

/**
 * Drains his.outbox to Kafka.
 *
 * This loop is what makes the outbox pattern work: order creation commits the
 * event to the database and returns, and getting it onto the broker is solely
 * this relay's job. Three consequences worth being explicit about:
 *
 *   * An order is never lost. If the broker is down the row simply stays
 *     unpublished and is retried until it lands.
 *   * Delivery is at-least-once, not exactly-once. A crash between the publish
 *     and the row being marked published re-sends on restart, so consumers must
 *     be idempotent — the bridge claims events by id, and this service upserts
 *     results on the OpenELIS reference.
 *   * Per-order ordering is preserved. Rows go out in outbox_id order and the
 *     batch STOPS at the first failure, so a later event for the same order can
 *     never overtake an earlier one.
 */
const BATCH_SIZE = 50;
const IDLE_MS = 1_000;
const BACKOFF_MS = 5_000;
const PRUNE_EVERY_MS = 10 * 60_000;
const KEEP_PUBLISHED_DAYS = 7;

export class OutboxRelay {
  private running = false;
  private nextPrune = Date.now() + PRUNE_EVERY_MS;

  start(): void {
    if (this.running) return;
    this.running = true;
    logger.info('Outbox relay started');
    void this.loop();
  }

  stop(): void {
    this.running = false;
  }

  private async loop(): Promise<void> {
    while (this.running) {
      let delay = IDLE_MS;
      try {
        const { published, stalled } = await this.drain();
        if (stalled) delay = BACKOFF_MS;
        else if (published > 0) delay = 0; // more may be waiting

        if (Date.now() >= this.nextPrune) {
          await this.prune();
          this.nextPrune = Date.now() + PRUNE_EVERY_MS;
        }
      } catch (error) {
        logger.error(`Outbox relay iteration failed: ${(error as Error).message}`);
        delay = BACKOFF_MS;
      }
      if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }

  private async drain(): Promise<{ published: number; stalled: boolean }> {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      // SKIP LOCKED so a second instance takes different rows rather than
      // blocking. Rows stay locked until commit, which is what stops two
      // relays publishing the same event.
      const batch = await client.query(
        `SELECT outbox_id, topic, partition_key, payload::text AS payload, correlation_id
           FROM his.outbox
          WHERE published_at IS NULL
          ORDER BY outbox_id
          LIMIT $1
          FOR UPDATE SKIP LOCKED`,
        [BATCH_SIZE],
      );

      if (batch.rowCount === 0) {
        await client.query('ROLLBACK');
        return { published: 0, stalled: false };
      }

      let published = 0;
      let stalled = false;

      for (const row of batch.rows as Row[]) {
        try {
          await eventPublisher.publishRaw(
            String(row.topic),
            String(row.partition_key),
            String(row.payload),
            row.correlation_id === null ? crypto.randomUUID() : String(row.correlation_id),
          );
          await client.query('UPDATE his.outbox SET published_at = now() WHERE outbox_id = $1', [
            row.outbox_id,
          ]);
          published++;
        } catch (error) {
          await client.query(
            'UPDATE his.outbox SET attempts = attempts + 1, last_error = $2 WHERE outbox_id = $1',
            [row.outbox_id, (error as Error).message],
          );
          logger.warn(
            `Outbox row ${String(row.outbox_id)} could not be published (${(error as Error).message}); will retry`,
          );
          // Stop rather than skip ahead: publishing a later event for the same
          // order before this one would reorder the stream.
          stalled = true;
          break;
        }
      }

      await client.query('COMMIT');
      if (published > 0) logger.info(`Outbox relay published ${published} event(s)`);
      return { published, stalled };
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }

  private async prune(): Promise<void> {
    const result = await pool.query(
      `DELETE FROM his.outbox
        WHERE published_at IS NOT NULL
          AND published_at < now() - make_interval(days => $1)`,
      [KEEP_PUBLISHED_DAYS],
    );
    if ((result.rowCount ?? 0) > 0) {
      logger.info(`Pruned ${result.rowCount} published outbox row(s)`);
    }
  }
}

export const outboxRelay = new OutboxRelay();
