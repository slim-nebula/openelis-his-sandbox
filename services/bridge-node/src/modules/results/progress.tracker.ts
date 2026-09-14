import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { eventPublisher } from '@config/kafka.js';
import type { FhirResource } from '@fhir/types.js';
import type { OrderTrackingModel, TrackedOrder } from '@modules/orders/models/order-tracking.model.js';
import type { EventClaimModel } from '@shared/models/event-claim.model.js';
import type { ReceivedModel } from './models/received.model.js';

/**
 * Tells the HIS where an order has got to inside the laboratory.
 *
 * WHY THIS EXISTS
 * Until this, an order went ACCEPTED_BY_LIS and then, some hours later,
 * RESULT_AVAILABLE. Everything in between was silence, and silence is
 * indistinguishable from "lost". The commonest question a ward asks a
 * laboratory — "where is my test?" — had no answer in the ordering system, so it
 * was asked by telephone.
 *
 * WHAT IT IS BUILT FROM
 * Nothing new is fetched. OpenELIS already pushes ServiceRequest, Specimen and
 * Task alongside the results, and the bridge already stores them; it simply read
 * only the DiagnosticReports and ignored the rest. This turns what was already
 * arriving into progress — so it needs no credential, no polling loop against
 * OpenELIS, and no second integration to keep working.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 * A preliminary DiagnosticReport carries a value the laboratory has NOT
 * validated. This publishes the fact that such a report exists, and never the
 * number in it. A clinician learning that a result is ready is useful; a
 * clinician acting on an unvalidated potassium is a patient safety incident.
 */

/** The system OpenELIS stamps on ITS accession number. */
const ACCESSION_SYSTEM = 'http://openelis-global.org/samp_labNo';

const asArray = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? (value as Record<string, unknown>[]) : [];

/**
 * The laboratory's own accession number — what a human quotes on the telephone,
 * and the only identifier the two systems share that a laboratory technician
 * recognises.
 *
 * The SYSTEM is what makes this trustworthy, and checking only for a value was
 * the first mistake here. OpenELIS echoes our own ServiceRequest back with
 * `requisition` set to the HIS order number under our own system, so a bare
 * presence check reported every order as "in the laboratory" the moment it was
 * imported — and then quoted the order number back as if it were an accession.
 * 102 of 130 requests were echoes; one was real.
 */
const accessionOf = (request: FhirResource): string | null => {
  const requisition = request.requisition as Record<string, unknown> | undefined;
  if (!requisition || requisition.system !== ACCESSION_SYSTEM) return null;
  const value = requisition.value;
  return typeof value === 'string' && value.trim().length > 0 ? value : null;
};

/**
 * Maps what OpenELIS says about a ServiceRequest onto something a clinician can
 * act on.
 *
 * Coarse on purpose. OpenELIS distinguishes twenty-one sample and analysis
 * states, most of which are internal to a laboratory's workflow; a ward needs to
 * know whether the sample arrived, whether testing is happening, and whether a
 * result is ready. Publishing the finer states would put a vocabulary in the HIS
 * that only means something to the laboratory.
 */
const progressOf = (request: FhirResource, accession: string | null): string | null => {
  // Accessioned: the sample is physically in the laboratory and has been given a
  // number. Without an accession this is only our own request echoed back, which
  // says nothing new.
  if (request.status === 'active' && accession !== null) return 'IN_LABORATORY';

  // 'completed' is deliberately absent: the result path already reports it
  // through lab.result.released, and reporting it twice invites the two to
  // disagree.
  return null;
};

export class ProgressTracker {
  private running = false;
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly received: ReceivedModel,
    private readonly tracking: OrderTrackingModel,
    private readonly claims: EventClaimModel,
  ) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    // Behind the result correlator's own first pass: both walk the same received
    // resources, and the correlator's work is the one a patient is waiting on.
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
        await this.sweep();
      } catch (error) {
        logger.error(`Progress sweep failed: ${(error as Error).message}`);
      }
      if (!this.running) break;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, 15_000);
      });
    }
  }

  private async sweep(): Promise<void> {
    for (const { content: request } of await this.received.unprocessed('ServiceRequest')) {
      const tracked = await this.resolve(request);

      // Not ours, or its chain has not arrived yet. Left unprocessed so the next
      // sweep tries again — the same patience the result correlator needs, and
      // for the same reason: OpenELIS pushes the pieces of one order in several
      // bundles.
      if (!tracked) continue;

      const accession = accessionOf(request);
      const progress = progressOf(request, accession);

      if (progress !== null) await this.publish(tracked, progress, accession);

      await this.received.markProcessed('ServiceRequest', request.id as string);
    }
  }

  /**
   * Walks the ServiceRequest back to the order the bridge published.
   *
   * The same shape as the result correlator's walk, and needed for the same
   * reason: what OpenELIS pushes back is ITS resource, not ours.
   */
  private async resolve(request: FhirResource): Promise<TrackedOrder | null> {
    if (typeof request.id === 'string') {
      const direct = await this.tracking.byServiceRequestId(request.id);
      if (direct) return direct;
    }

    for (const basedOn of asArray(request.basedOn)) {
      const reference = basedOn.reference;
      if (typeof reference !== 'string') continue;
      const parentId = reference.split('/').filter((s) => s.length > 0).pop();
      if (!parentId) continue;
      const viaParent = await this.tracking.byServiceRequestId(parentId);
      if (viaParent) return viaParent;
    }

    for (const identifier of asArray(request.identifier)) {
      const value = identifier.value;
      if (typeof value !== 'string' || value.trim().length === 0) continue;
      const viaIdentifier = await this.tracking.byOrderNumber(value);
      if (viaIdentifier) return viaIdentifier;
    }

    return null;
  }

  /**
   * Publishes once per order and state.
   *
   * OpenELIS re-pushes the same resource whenever anything about the sample
   * changes, so without this the HIS would receive "in the laboratory" a dozen
   * times for one order — and each would be an audit row and a notification.
   */
  private async publish(
    tracked: TrackedOrder,
    progress: string,
    accession: string | null,
  ): Promise<void> {
    const key = `progress:${tracked.orderNumber}:${progress}`;
    if (!(await this.claims.claim(key, 'lab.order.progress'))) return;

    try {
      await eventPublisher.publish(
        config.kafka.topics.orderProgress,
        tracked.orderNumber,
        {
          eventId: key,
          eventType: 'lab.order.progress',
          orderNumber: tracked.orderNumber,
          progress,
          accessionNumber: accession,
          occurredAt: new Date().toISOString(),
        },
        tracked.correlationId ?? key,
      );

      logger.info(`Order ${tracked.orderNumber} is ${progress} (accession ${accession ?? 'none'})`);
    } catch (error) {
      // Release the claim so the next sweep retries. Keeping it would mean one
      // failed publish silently costs that order its progress for ever.
      await this.claims.release(key);
      throw error;
    }
  }
}
