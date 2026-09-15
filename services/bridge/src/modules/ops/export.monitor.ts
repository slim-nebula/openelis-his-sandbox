import { config, catalogueDiscoveryConfigured } from '@config/env.js';
import { logger } from '@config/logger.js';
import { OpenElisClient, type IExportSubscription } from '@modules/catalogue/clients/openelis.client.js';
import type { OpsModel } from './models/ops.model.js';

/**
 * Asks OpenELIS whether it is still pushing released results to us, and judges
 * the answer.
 *
 * Without this, a laboratory that has stopped delivering results looks exactly
 * like a laboratory with nothing ready: the bridge receives nothing either way.
 * Orders sit in ACCEPTED_BY_LIS and the detection mechanism is a clinician
 * eventually asking where a result went.
 *
 * The probe is separated from the timer that drives it so the same check can be
 * run on demand. An operator asking "is it working right now?" should not have
 * to wait for the next cycle, and a test should not have to sleep for one.
 */
export class ExportHealthProbe {
  constructor(private readonly ops: OpsModel) {}

  private looksLikeUs(endpoint: string): boolean {
    const lower = endpoint.toLowerCase();
    return (
      lower.includes('/fhir') &&
      (lower.includes('bridge') || lower.includes(config.openElis.publicFhirHost.toLowerCase()))
    );
  }

  /**
   * OK, STALE or FAILING — judged against what OpenELIS says it INTENDS to do
   * rather than a threshold invented here, so the check stays correct if the
   * laboratory changes its push cadence.
   */
  private judge(subscription: IExportSubscription): { verdict: string; detail: string } {
    if ((subscription.lastStatus ?? '').toUpperCase() !== 'SUCCEEDED') {
      return {
        verdict: 'FAILING',
        detail: `last attempt ${subscription.lastStatus ?? 'unknown'}, ${subscription.failedLast24h ?? 0} failures in 24h`,
      };
    }

    if (!subscription.lastSuccess) {
      return { verdict: 'FAILING', detail: 'the subscription has never succeeded' };
    }

    // A few cycles of grace: one missed push is a hiccup, several in a row is an
    // outage.
    const cadenceMinutes = Math.max(subscription.maxIntervalMinutes ?? 1, 1);
    const toleranceMs = cadenceMinutes * config.openElis.exportStaleCycles * 60_000;
    const ageMs = Date.now() - new Date(subscription.lastSuccess).getTime();
    const ageMinutes = Math.round(ageMs / 60_000);

    return ageMs > toleranceMs
      ? {
          verdict: 'STALE',
          detail: `last successful push ${ageMinutes} min ago, expected every ${cadenceMinutes} min`,
        }
      : {
          verdict: 'OK',
          detail: `last push ${ageMinutes} min ago, ${subscription.totalLast24h ?? 0} in 24h`,
        };
  }

  async run(): Promise<{ verdict: string; detail: string }> {
    let ours: IExportSubscription | null = null;
    let verdict: string;
    let detail: string;

    try {
      const client = new OpenElisClient();
      await client.authenticate();
      const subscriptions = await client.dataExportStatus();

      // Only the subscription pointing at us matters. OpenELIS may push to
      // several places, and another one being broken is not our outage.
      ours = subscriptions.find((s) => this.looksLikeUs(s.endpoint)) ?? subscriptions[0] ?? null;

      if (!ours) {
        verdict = 'FAILING';
        detail = 'OpenELIS has no export subscription pointing at the bridge';
      } else {
        ({ verdict, detail } = this.judge(ours));
      }
    } catch (error) {
      // Not knowing is its own state. Reporting OK because the question could
      // not be asked would be worse than saying so plainly.
      verdict = 'UNREACHABLE';
      detail = (error as Error).message;
    }

    await this.ops.recordExportCheck(verdict, ours, detail);
    return { verdict, detail };
  }
}

/** Runs the probe on a timer and says something only when the verdict changes. */
export class ExportMonitor {
  private running = false;
  private timer: NodeJS.Timeout | null = null;
  private lastVerdict: string | null = null;

  constructor(private readonly probe: ExportHealthProbe) {}

  start(): void {
    if (this.running) return;

    if (!catalogueDiscoveryConfigured()) {
      logger.info('Export monitoring is off: no OpenELIS REST credentials configured');
      return;
    }

    this.running = true;
    // Let OpenELIS finish starting, or restarting the whole stack reports
    // UNREACHABLE for no useful reason.
    this.timer = setTimeout(() => void this.loop(), 60_000);
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private async loop(): Promise<void> {
    while (this.running) {
      try {
        const { verdict, detail } = await this.probe.run();

        // Logged on CHANGE, not every cycle. A line every five minutes saying
        // everything is fine trains people to stop reading the log, which is
        // worse than not logging at all.
        if (verdict !== this.lastVerdict) {
          if (verdict === 'OK') logger.info(`Result push channel is healthy (${detail})`);
          else logger.warn(`Result push channel is ${verdict}: ${detail}`);
          this.lastVerdict = verdict;
        }
      } catch (error) {
        logger.error(`Export status check failed unexpectedly: ${(error as Error).message}`);
      }

      if (!this.running) break;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, config.openElis.exportCheckMinutes * 60_000);
      });
    }
  }
}

/**
 * Runs the retention sweep daily, offset from startup.
 *
 * NOT at startup: a crash-loop would otherwise run a bulk DELETE every time the
 * container came up, which is the worst possible moment.
 */
export class RetentionService {
  private running = false;
  private timer: NodeJS.Timeout | null = null;

  constructor(private readonly ops: OpsModel) {}

  start(): void {
    if (this.running) return;

    if (config.retention.sweepHours <= 0) {
      logger.info('Retention sweeping is off (RETENTION_SWEEP_HOURS=0)');
      return;
    }

    this.running = true;
    this.timer = setTimeout(() => void this.loop(), 5 * 60_000);
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private async loop(): Promise<void> {
    while (this.running) {
      try {
        const results = await this.ops.runRetentionSweep();
        const removed = results.reduce((total, result) => total + result.deleted, 0);
        if (removed > 0) {
          const detail = results
            .filter((result) => result.deleted > 0)
            .map((result) => `${result.table} -${result.deleted}`)
            .join(', ');
          logger.info(`Retention sweep removed ${removed} row(s): ${detail}`);
        }
      } catch (error) {
        logger.error(`Retention sweep failed: ${(error as Error).message}`);
      }

      if (!this.running) break;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, config.retention.sweepHours * 3_600_000);
      });
    }
  }
}
