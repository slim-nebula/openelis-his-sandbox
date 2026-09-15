import { logger } from '@config/logger.js';
import { lastPollAgeSeconds, publishIntegrationGauges } from '@config/metrics.js';
import type { OpsModel } from './models/ops.model.js';

/**
 * The four numbers that say whether the integration is actually working.
 *
 * WHY THESE FOUR, AND WHY THEY DID NOT EXIST BEFORE
 * The bridge already exposed request counts and durations, which answer "is the
 * process up and serving". Every failure mode that actually costs a patient
 * their result is INVISIBLE in those:
 *
 *   an order published and never polled     — no request fails, none is made
 *   OpenELIS stopping its poll entirely     — the busiest endpoint simply goes quiet
 *   a catalogue sync failing months ago     — yesterday's menu still serves fine
 *   dead letters accumulating               — each one was handled correctly
 *
 * All four look exactly like a healthy idle system, which is why they need a
 * gauge rather than an error rate. A quiet laboratory and a broken integration
 * produce identical graphs until something measures the AGE of things.
 *
 * WHY A TIMER RATHER THAN A SCRAPE CALLBACK
 * Prometheus scrapes /metrics, and a callback would run these queries on
 * whatever schedule the scraper chose — including several times a second if
 * someone pointed two scrapers at it. Refreshing on our own timer bounds the
 * database cost at one cheap query every thirty seconds regardless of who is
 * watching, and a gauge thirty seconds stale is indistinguishable from a fresh
 * one at the thresholds these alerts use (minutes to days).
 *
 * NOTHING IS PUBLISHED UNTIL A REFRESH HAS ACTUALLY SUCCEEDED. See
 * config/metrics.ts: the gauges are not constructed until this class hands over
 * real numbers, so a collector that has never read the database produces ABSENT
 * metrics rather than four reassuring zeroes. That is the mistake this guards
 * against, and it was made in the .NET version first — a query it could not
 * materialise left every gauge at 0, which reads as "nothing stuck, no dead
 * letters, catalogue fresh", and quietly satisfied every alert in alerts.yml.
 */
export class IntegrationGauges {
  private running = false;
  private timer: NodeJS.Timeout | null = null;
  private live = false;

  constructor(private readonly ops: OpsModel) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    // Behind the database wait in server.ts.
    this.timer = setTimeout(() => void this.loop(), 20_000);
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private async loop(): Promise<void> {
    while (this.running) {
      try {
        await this.refresh();
        if (!this.live) {
          this.live = true;
          logger.info('Integration gauges are live');
        }
      } catch (error) {
        // Already-published gauges keep their previous values rather than being
        // zeroed: a failed refresh is not evidence that nothing is stuck, and
        // zeroing would resolve a firing alert on no information at all. Gauges
        // that have NEVER refreshed stay absent, which is the honest answer to
        // "we do not know".
        logger.warn(`Could not refresh the integration gauges: ${(error as Error).message}`);
      }

      if (!this.running) break;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, 30_000);
      });
    }
  }

  private async refresh(): Promise<void> {
    const values = await this.ops.gaugeValues();
    publishIntegrationGauges({
      ...values,
      // The one gauge not backed by a table: nothing records a poll, because a
      // poll that returns nothing writes nothing. Stamped in memory by the
      // search handler instead — which is why it reads as "never polled since
      // this process started" after a restart rather than as an outage, and why
      // the alert on it has to tolerate that.
      lastPollAgeSeconds: lastPollAgeSeconds(),
    });
  }
}
