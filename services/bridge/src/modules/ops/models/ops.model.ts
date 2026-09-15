import { config } from '@config/env.js';
import { query, queryOne, type Row } from '@config/db.js';
import { toDateOnly, toIso, toNumber } from '@shared/utils/serialization.utils.js';
import type { IExportSubscription } from '@modules/catalogue/clients/openelis.client.js';

/**
 * The operational views: what was taken on, what became of it, and whether the
 * channel results arrive on is alive.
 *
 * EVERY COUNT AND EVERY AGE IS CAST IN SQL, and that is not decoration.
 * Postgres `count(*)` is bigint and `extract(epoch …)` is numeric, both of which
 * node-postgres returns as STRINGS to avoid silent precision loss. A string fed
 * to a Prometheus gauge publishes NaN, which reads as a missing metric; a string
 * in a JSON count reads as "7" rather than 7 and quietly breaks any consumer
 * doing arithmetic. The .NET version paid for this twice with Dapper — see the
 * bridge-dapper-type-mapping memory — so the casts are here and the callers
 * coerce as well.
 */

export interface IReconciliationDay {
  day: string | null;
  accepted: number;
  acceptedByLis: number;
  rejectedByLis: number;
  outstanding: number;
  outstandingOverAnHour: number;
  outstandingOverADay: number;
  resulted: number;
}

export interface IGaugeValues {
  oldestRequestedTaskAgeSeconds: number;
  deadLetters: number;
  catalogueAgeSeconds: number;
}

export interface IExportCheck {
  checkedAt: string | null;
  verdict: string;
  endpoint: string | null;
  lastStatus: string | null;
  lastSuccess: string | null;
  failedLast24h: number | null;
  totalLast24h: number | null;
  detail: string | null;
}

export interface ISweepResult {
  table: string;
  days: number;
  deleted: number;
  retained: number;
}

const toExportCheck = (row: Row): IExportCheck => ({
  checkedAt: toIso(row.checked_at),
  verdict: String(row.verdict),
  endpoint: row.endpoint === null || row.endpoint === undefined ? null : String(row.endpoint),
  lastStatus: row.last_status === null || row.last_status === undefined ? null : String(row.last_status),
  lastSuccess: toIso(row.last_success),
  failedLast24h: row.failed_last_24h === null || row.failed_last_24h === undefined ? null : Number(row.failed_last_24h),
  totalLast24h: row.total_last_24h === null || row.total_last_24h === undefined ? null : Number(row.total_last_24h),
  detail: row.detail === null || row.detail === undefined ? null : String(row.detail),
});

export class OpsModel {
  /**
   * The three table-backed gauge values, in ONE round trip.
   *
   * Read together because they are alerted on together: three separate queries
   * would be three chances for a partial refresh to publish an inconsistent set.
   */
  async gaugeValues(): Promise<IGaugeValues> {
    const row = await queryOne<Row>(
      `SELECT
           coalesce(extract(epoch FROM now() - (
               SELECT min(r.last_updated)
                 FROM bridge.fhir_resources r
                 LEFT JOIN bridge.order_tracking t ON t.fhir_task_id = r.resource_id
                WHERE r.resource_type = 'Task'
                  AND r.content ->> 'status' = 'requested'
                  -- A result came back, so the order manifestly WAS delivered,
                  -- whatever the Task status still says. The acknowledgement is
                  -- the thing that went missing, and a missing acknowledgement
                  -- is not a waiting patient.
                  --
                  -- Without this the gauge measures "un-acknowledged", which is
                  -- not what the alert claims and not what anyone would get out
                  -- of bed for: it fires for ever on any order whose
                  -- accept-write was lost, long after its result reached the
                  -- ward.
                  AND NOT EXISTS (
                      SELECT 1 FROM bridge.forwarded_results f
                       WHERE f.order_id = t.order_id))), 0)
               ::double precision AS oldest_requested_seconds,
           (SELECT count(*) FROM bridge.dead_letters)::int AS dead_letters,
           -- -1, not 0, for a catalogue that has never synced. Zero would mean
           -- "synced just now" -- the healthiest possible reading for the least
           -- healthy possible state.
           coalesce(extract(epoch FROM now() - (
               SELECT max(synced_at) FROM bridge.test_catalogue)), -1)
               ::double precision AS catalogue_age_seconds`,
    );

    return {
      oldestRequestedTaskAgeSeconds: toNumber(row?.oldest_requested_seconds),
      deadLetters: toNumber(row?.dead_letters),
      catalogueAgeSeconds: toNumber(row?.catalogue_age_seconds, -1),
    };
  }

  /**
   * The ledger: what was taken on each day, and what became of it.
   *
   * EXISTS, not a join to forwarded_results. The join was the first version and
   * it silently INFLATED every other column: forwarded_results holds one row per
   * result VERSION, so an order corrected twice fanned out to three rows and was
   * counted three times as "taken on". The ledger reported 388 orders against
   * 363 in the table.
   *
   * A reconciliation report that cannot count is worse than none: its entire
   * purpose is to be the number you trust when the alerts are quiet, and an
   * over-count hides a shortfall by filling it with duplicates.
   */
  async reconciliation(days: number): Promise<IReconciliationDay[]> {
    const rows = await query<Row>(
      `SELECT
           t.created_at::date                                        AS day,
           count(*)::int                                             AS accepted,
           count(*) FILTER (WHERE t.task_status = 'accepted')::int   AS accepted_by_lis,
           count(*) FILTER (WHERE t.task_status = 'rejected')::int   AS rejected_by_lis,
           count(*) FILTER (WHERE t.task_status = 'requested')::int  AS outstanding,
           -- Outstanding AND old. The first bucket is ordinary in-flight
           -- traffic; the second is the one worth reading.
           (count(*) FILTER (WHERE t.task_status = 'requested'
                               AND t.created_at < now() - interval '1 hour'))::int
                                                                     AS outstanding_over_an_hour,
           (count(*) FILTER (WHERE t.task_status = 'requested'
                               AND t.created_at < now() - interval '1 day'))::int
                                                                     AS outstanding_over_a_day,
           (count(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM bridge.forwarded_results f
                WHERE f.order_id = t.order_id)))::int                AS resulted
         FROM bridge.order_tracking t
        WHERE t.created_at >= now() - make_interval(days => $1::int)
        GROUP BY t.created_at::date
        ORDER BY t.created_at::date DESC`,
      [days],
    );

    return rows.map((row) => ({
      day: toDateOnly(row.day),
      accepted: toNumber(row.accepted),
      acceptedByLis: toNumber(row.accepted_by_lis),
      rejectedByLis: toNumber(row.rejected_by_lis),
      outstanding: toNumber(row.outstanding),
      outstandingOverAnHour: toNumber(row.outstanding_over_an_hour),
      outstandingOverADay: toNumber(row.outstanding_over_a_day),
      resulted: toNumber(row.resulted),
    }));
  }

  async deadLettersByDay(days: number): Promise<Map<string, number>> {
    const rows = await query<Row>(
      `SELECT created_at::date AS day, count(*)::int AS dead_letters
         FROM bridge.dead_letters
        WHERE created_at >= now() - make_interval(days => $1::int)
        GROUP BY created_at::date
        ORDER BY created_at::date DESC`,
      [days],
    );

    const byDay = new Map<string, number>();
    for (const row of rows) {
      const day = toDateOnly(row.day);
      if (day) byDay.set(day, toNumber(row.dead_letters));
    }
    return byDay;
  }

  /** What OpenELIS is publishing for polling — the Tasks, summarised. */
  async publishedTasks(limit: number): Promise<Record<string, unknown>[]> {
    const rows = await query<Row>(
      `SELECT content FROM bridge.fhir_resources
        WHERE resource_type = 'Task'
        ORDER BY last_updated
        LIMIT $1`,
      [limit],
    );

    return rows.map((row) => {
      const task = row.content as Record<string, unknown>;
      const basedOn = Array.isArray(task.basedOn) ? (task.basedOn as Record<string, unknown>[]) : [];
      return {
        taskId: task.id ?? null,
        status: task.status ?? null,
        owner: (task.owner as Record<string, unknown> | undefined)?.reference ?? null,
        basedOn: basedOn.map((reference) => reference.reference),
        description: task.description ?? null,
      };
    });
  }

  // --- Result push channel health -------------------------------------------

  async recordExportCheck(
    verdict: string,
    subscription: IExportSubscription | null,
    detail: string,
  ): Promise<void> {
    await query(
      `INSERT INTO bridge.export_status_checks
           (subscription_id, endpoint, verdict, last_status, last_success, last_attempt,
            failed_last_24h, total_last_24h, max_interval_minutes, detail)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
      [
        subscription?.id ?? null,
        subscription?.endpoint ?? null,
        verdict,
        subscription?.lastStatus ?? null,
        subscription?.lastSuccess ?? null,
        subscription?.lastAttempt ?? null,
        subscription?.failedLast24h ?? null,
        subscription?.totalLast24h ?? null,
        subscription?.maxIntervalMinutes ?? null,
        detail,
      ],
    );
  }

  async latestExportCheck(): Promise<IExportCheck | null> {
    const row = await queryOne<Row>(
      `SELECT checked_at, verdict, endpoint, last_status, last_success,
              failed_last_24h, total_last_24h, detail
         FROM bridge.export_status_checks ORDER BY checked_at DESC LIMIT 1`,
    );
    return row ? toExportCheck(row) : null;
  }

  async exportChecks(): Promise<IExportCheck[]> {
    const rows = await query<Row>(
      `SELECT checked_at, verdict, endpoint, last_status, last_success,
              failed_last_24h, total_last_24h, detail
         FROM bridge.export_status_checks ORDER BY checked_at DESC LIMIT 50`,
    );
    return rows.map(toExportCheck);
  }

  // --- Retention ------------------------------------------------------------

  /**
   * One table's worth of pruning.
   *
   * `days <= 0` means "keep everything", which has to be an available answer: a
   * laboratory under an audit hold cannot have its history swept because a
   * default said 30 days.
   */
  private async sweep(table: string, days: number, sql: string): Promise<ISweepResult> {
    const before = await queryOne<Row>(`SELECT count(*)::int AS total FROM bridge.${table}`);
    const retained = toNumber(before?.total);

    if (days <= 0) return { table, days, deleted: 0, retained };

    const deletedRows = await query(sql, [days]);
    const deleted = deletedRows.length;
    return { table, days, deleted, retained: retained - deleted };
  }

  /**
   * Removes what is no longer needed from the four tables that otherwise grow
   * for ever.
   *
   * The windows differ per table because the data does. Two rules hold across
   * all of them: nothing UNFINISHED is deleted whatever its age — an unprocessed
   * resource is a result that has not reached the patient's record yet, and age
   * is not evidence that it never will — and nothing is deleted that another
   * table still points at.
   *
   * fhir_resources is deliberately absent. It is what OpenELIS READS: an order
   * it has not yet polled, or a ServiceRequest it dereferences when a late
   * report arrives. Pruning it by age would delete the far side of a
   * conversation that is still going. It is bounded by the number of live
   * orders, not by time, so it does not belong in a time sweep.
   *
   * RETURNING is how the row count is taken: node-postgres reports rowCount for
   * a DELETE, but returning the ids makes the count explicit and survives a
   * driver that decides otherwise.
   */
  async runRetentionSweep(): Promise<ISweepResult[]> {
    const results: ISweepResult[] = [];

    // The inbound mirror. Only rows already correlated into a HIS result: a
    // report can arrive before the ServiceRequest that explains it, and pruning
    // the half that arrived first would strand the other half for ever.
    results.push(
      await this.sweep(
        'received_resources',
        config.retention.receivedDays,
        `DELETE FROM bridge.received_resources r
          WHERE r.processed = true
            AND r.received_at < now() - make_interval(days => $1::int)
          RETURNING r.resource_id`,
      ),
    );

    // Duplicate suppression. Useful only while a redelivery is plausible: Kafka
    // retention plus the largest outage anyone would replay through. Keeping it
    // longer does not make ordering safer, it just makes the primary-key index
    // bigger on the hot path of every incoming order.
    results.push(
      await this.sweep(
        'processed_events',
        config.retention.eventsDays,
        `DELETE FROM bridge.processed_events
          WHERE processed_at < now() - make_interval(days => $1::int)
          RETURNING event_key`,
      ),
    );

    // Health history, read when explaining an incident. One row every
    // EXPORT_CHECK_MINUTES is ~105k rows a year at the default cadence.
    results.push(
      await this.sweep(
        'export_status_checks',
        config.retention.exportChecksDays,
        `DELETE FROM bridge.export_status_checks
          WHERE checked_at < now() - make_interval(days => $1::int)
          RETURNING id`,
      ),
    );

    // Dead letters are kept longest and are the one table where deletion is
    // genuinely lossy: each row is a request that never completed. The window is
    // long enough that anything still here has been consciously left rather than
    // merely not noticed.
    results.push(
      await this.sweep(
        'dead_letters',
        config.retention.deadLettersDays,
        `DELETE FROM bridge.dead_letters
          WHERE created_at < now() - make_interval(days => $1::int)
          RETURNING id`,
      ),
    );

    return results;
  }
}
