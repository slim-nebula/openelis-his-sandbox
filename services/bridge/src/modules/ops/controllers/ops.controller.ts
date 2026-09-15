import type { Request, Response } from 'express';
import { config, catalogueDiscoveryConfigured } from '@config/env.js';
import { problemResponse } from '@core/middleware/error.js';
import type { DeadLetterModel } from '@shared/models/dead-letter.model.js';
import type { ExportHealthProbe } from '../export.monitor.js';
import type { OpsModel } from '../models/ops.model.js';

/**
 * The operational surface. Everything here either changes something or
 * describes the health of the integration in detail, and both are worth a
 * bearer token — the second because "which orders are outstanding and which
 * failed" is a description of real patients' care, and it does not become public
 * because it is a GET.
 */
export class OpsController {
  constructor(
    private readonly ops: OpsModel,
    private readonly deadLetters: DeadLetterModel,
    private readonly probe: ExportHealthProbe,
  ) {}

  /** What the bridge is publishing for OpenELIS to poll, and what it could not correlate. */
  orders = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.ops.publishedTasks(config.maxSearchResults));
  };

  deadLetterQueue = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.deadLetters.recent());
  };

  /**
   * The ledger: what was taken on, and what became of it.
   *
   * The alerts answer "is something wrong now". This answers "did everything we
   * accepted actually get a result", which no alert can — a slow leak of one
   * order a day crosses no threshold and stays invisible until somebody counts.
   * Pure read over data already kept.
   */
  reconciliation = async (req: Request, res: Response): Promise<void> => {
    // Clamped rather than trusted. Unbounded, this scans the whole table on an
    // endpoint anyone with the operator token can call in a loop.
    const requested = Number(req.query['days']);
    const days = Number.isFinite(requested) ? Math.min(Math.max(Math.trunc(requested), 1), 90) : 7;

    const [ledger, deadLettersByDay] = await Promise.all([
      this.ops.reconciliation(days),
      this.ops.deadLettersByDay(days),
    ]);

    const sum = (pick: (row: (typeof ledger)[number]) => number): number =>
      ledger.reduce((total, row) => total + pick(row), 0);

    res.json({
      days,
      // Totals first: the question is usually "does this add up", and that is
      // answerable without reading every row.
      //
      // `outstandingOverAnHour` is deliberately NOT here while byDay carries it.
      // An hour-old order is ordinary in-flight traffic when summed across a
      // week — the total would read as alarming and mean nothing. Per day it is
      // the column that distinguishes a busy afternoon from a stuck queue.
      totals: {
        accepted: sum((row) => row.accepted),
        acceptedByLis: sum((row) => row.acceptedByLis),
        rejectedByLis: sum((row) => row.rejectedByLis),
        outstanding: sum((row) => row.outstanding),
        outstandingOverADay: sum((row) => row.outstandingOverADay),
        resulted: sum((row) => row.resulted),
        deadLetters: [...deadLettersByDay.values()].reduce((total, count) => total + count, 0),
      },
      byDay: ledger.map((row) => ({
        day: row.day,
        accepted: row.accepted,
        acceptedByLis: row.acceptedByLis,
        rejectedByLis: row.rejectedByLis,
        outstanding: row.outstanding,
        outstandingOverAnHour: row.outstandingOverAnHour,
        outstandingOverADay: row.outstandingOverADay,
        resulted: row.resulted,
        deadLetters: (row.day !== null ? deadLettersByDay.get(row.day) : undefined) ?? 0,
      })),
    });
  };

  /**
   * Answers "is OpenELIS still pushing results to us", which nothing else could
   * tell you: a bridge receiving nothing looks the same as a quiet laboratory.
   */
  exportStatus = async (_req: Request, res: Response): Promise<void> => {
    const latest = await this.ops.latestExportCheck();
    res.json(latest ?? { verdict: 'UNKNOWN', detail: 'no check has run yet' });
  };

  exportHistory = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.ops.exportChecks());
  };

  /**
   * Runs the check now rather than waiting for the next cycle. An operator
   * asking "is it working right now" should not have to wait five minutes.
   */
  runExportCheck = async (_req: Request, res: Response): Promise<void> => {
    if (!catalogueDiscoveryConfigured()) {
      problemResponse(res, 501, 'No OpenELIS REST credentials configured.');
      return;
    }
    res.json(await this.probe.run());
  };

  /**
   * Runs the retention sweep now. The timer is the normal path; this exists so
   * the windows can be verified against real data rather than trusted, and so a
   * database filling up can be dealt with at the time rather than at 03:00.
   */
  runRetentionSweep = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.ops.runRetentionSweep());
  };
}
