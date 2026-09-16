import { randomUUID } from 'node:crypto';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { eventPublisher } from '@config/kafka.js';
import type { FhirResource } from '@fhir/types.js';
import type { FhirModel } from '@modules/fhir-api/models/fhir.model.js';
import type { OrderTrackingModel, TrackedOrder } from '@modules/orders/models/order-tracking.model.js';
import type { DeadLetterModel } from '@shared/models/dead-letter.model.js';
import type { EventClaimModel } from '@shared/models/event-claim.model.js';
import type { ForwardedResultModel } from './models/forwarded.model.js';
import type { IObservation, ReceivedModel } from './models/received.model.js';
import { analyteCode, analyteName, flatten } from './result.flatten.js';

/**
 * Turns what OpenELIS pushes back into HIS-shaped results.
 *
 * OpenELIS reports a released analysis as a DiagnosticReport whose basedOn
 * points at a per-analysis ServiceRequest, which in turn points at the
 * ServiceRequest the bridge originally published. Those resources arrive
 * independently and in no guaranteed order, so correlation runs on a timer over
 * the inbound mirror rather than inline on the HTTP push: a report whose chain
 * has not landed yet is simply left for the next pass, and only dead-lettered
 * once it has been unresolvable for BRIDGE_RESULT_CORRELATION_RETRY_MINUTES.
 */

/**
 * Statuses that must reach the HIS. A laboratory does not only publish results,
 * it corrects and withdraws them, and each of those is as clinically
 * significant as the original.
 *
 * entered-in-error is included deliberately: it retracts a result the clinician
 * has already seen. Suppressing it would leave a withdrawn value on screen
 * indefinitely, which is worse than showing a stale one, because nothing
 * signals that it is wrong.
 */
const RELEASED_STATUSES = ['final', 'amended', 'corrected', 'entered-in-error'];

/** A retracted result carries no value — only the retraction. */
const RETRACTED_STATUS = 'entered-in-error';

/** The last segment of a FHIR reference, which is its id. */
const idOf = (reference: unknown): string | null => {
  const value = (reference as Record<string, unknown> | undefined)?.reference;
  if (typeof value !== 'string' || value.trim().length === 0) return null;
  const segments = value.split('/').filter((s) => s.length > 0);
  return segments.length === 0 ? null : (segments[segments.length - 1] as string);
};

const asArray = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? (value as Record<string, unknown>[]) : [];

export class ResultCorrelator {
  private running = false;
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly received: ReceivedModel,
    private readonly forwarded: ForwardedResultModel,
    private readonly tracking: OrderTrackingModel,
    private readonly claims: EventClaimModel,
    private readonly deadLetters: DeadLetterModel,
    // Only ever used to CLOSE a Task whose result has come back — see
    // closeTaskIfStillOutstanding. The correlator publishes nothing through it.
    private readonly store: FhirModel,
  ) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    // Give the rest of the stack a moment before the first sweep.
    this.timer = setTimeout(() => void this.loop(), 15_000);
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
        logger.error(`Result correlation sweep failed: ${(error as Error).message}`);
      }
      if (!this.running) break;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, 10_000);
      });
    }
  }

  private async sweep(): Promise<void> {
    const reports = await this.received.unprocessed('DiagnosticReport');
    if (reports.length === 0) return;

    for (const { content: report, receivedAt } of reports) {
      const status = typeof report.status === 'string' ? report.status : 'unknown';
      const reportId = report.id as string;

      if (!RELEASED_STATUSES.includes(status)) {
        // Not validated yet, so the VALUE stays in the laboratory. But the fact
        // that a result exists and is waiting on a signature is safe to tell the
        // ward, and is the difference between "no news" and "nearly there".
        //
        // Publishing the number here instead would be a patient safety incident
        // waiting to happen: an unvalidated potassium looks exactly like a
        // validated one on a screen.
        const pending = await this.resolveOrder(report);
        if (pending) await this.publishProgress(pending, 'AWAITING_VALIDATION');

        await this.received.markProcessed('DiagnosticReport', reportId);
        continue;
      }

      const tracked = await this.resolveOrder(report);
      if (!tracked) {
        const ageMs = Date.now() - new Date(receivedAt ?? Date.now()).getTime();
        if (ageMs > config.correlationRetryMinutes * 60_000) {
          await this.deadLetters.record(
            'fhir:DiagnosticReport',
            `Could not correlate DiagnosticReport/${reportId} to a HIS order after ` +
              `${Math.round(ageMs / 60_000)} min`,
            JSON.stringify(report),
            null,
          );
          await this.received.markProcessed('DiagnosticReport', reportId);

          await eventPublisher.publish(
            config.kafka.topics.resultFailed,
            reportId,
            {
              eventId: randomUUID(),
              openelisResultRef: `DiagnosticReport/${reportId}`,
              status: 'UNCORRELATED',
              detail: "No HIS order matches this report's ServiceRequest chain",
            },
            randomUUID(),
          );
        } else {
          logger.info(
            `DiagnosticReport/${reportId} not correlated yet (${Math.round(ageMs / 1000)}s old); ` +
              'waiting for its ServiceRequest chain',
          );
        }
        continue;
      }

      await this.forward(report, tracked, status, receivedAt);
    }
  }

  /**
   * Walks DiagnosticReport -> ServiceRequest -> ServiceRequest back to the order
   * the bridge published, with progressively looser fallbacks.
   */
  private async resolveOrder(report: FhirResource): Promise<TrackedOrder | null> {
    for (const basedOn of asArray(report.basedOn)) {
      const srId = idOf(basedOn);
      if (!srId) continue;

      // 1. The report points straight at a ServiceRequest we published.
      const direct = await this.tracking.byServiceRequestId(srId);
      if (direct) return direct;

      const analysis = await this.received.get('ServiceRequest', srId);
      if (!analysis) continue;

      // 2. OpenELIS's per-analysis ServiceRequest points back at ours.
      for (const parent of asArray(analysis.content.basedOn)) {
        const parentId = idOf(parent);
        if (!parentId) continue;

        const viaParent = await this.tracking.byServiceRequestId(parentId);
        if (viaParent) return viaParent;

        const parentSr = await this.received.get('ServiceRequest', parentId);
        if (parentSr) {
          const viaParentIdentifier = await this.matchByOrderNumber(parentSr.content);
          if (viaParentIdentifier) return viaParentIdentifier;
        }
      }

      // 3. The order number travelled on the ServiceRequest identifier.
      const viaIdentifier = await this.matchByOrderNumber(analysis.content);
      if (viaIdentifier) return viaIdentifier;
    }

    return null;
  }

  private async matchByOrderNumber(serviceRequest: FhirResource): Promise<TrackedOrder | null> {
    for (const identifier of asArray(serviceRequest.identifier)) {
      const value = identifier.value;
      if (typeof value !== 'string' || value.trim().length === 0) continue;
      const match = await this.tracking.byOrderNumber(value);
      if (match) return match;
    }
    return null;
  }

  /**
   * Same claim-once behaviour as the progress tracker: OpenELIS re-pushes a
   * preliminary report every time the technician touches it, and the ward does
   * not need telling twice.
   */
  private async publishProgress(tracked: TrackedOrder, progress: string): Promise<void> {
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
          accessionNumber: null,
          occurredAt: new Date().toISOString(),
        },
        tracked.correlationId ?? key,
      );
    } catch (error) {
      await this.claims.release(key);
      throw error;
    }
  }

  /**
   * Every Observation the report references, in reference order, plus a count of
   * the ones that have not arrived yet.
   *
   * The count is the interesting half. OpenELIS pushes the pieces of one report
   * in several bundles and in no guaranteed order, so a report whose
   * Observations are still in flight is INDISTINGUISHABLE from a panel whose
   * components were dropped. Forwarding immediately would publish a partial
   * panel as though it were the whole report — and because the forward is
   * claimed per version, the missing analytes would never arrive afterwards.
   *
   * An empty result list is not a missing observation. Some OpenELIS analyses
   * report only a narrative conclusion, which reaches the HIS through the
   * report-level fields with no components at all.
   */
  private async observationsOf(
    report: FhirResource,
  ): Promise<{ resolved: IObservation[]; missing: number }> {
    const resolved: IObservation[] = [];
    let missing = 0;

    for (const reference of asArray(report.result)) {
      const id = idOf(reference);
      if (!id) {
        missing++;
        continue;
      }
      const observation = await this.received.observation(id);
      if (!observation) missing++;
      else resolved.push(observation);
    }

    return { resolved, missing };
  }

  /**
   * When the specimen was drawn, as the laboratory recorded it.
   *
   * NOT from Observation.effective. FHIR convention says `effective` is the
   * diagnostically relevant time and US Core describes it as "typically the time
   * of specimen collection" — but OpenELIS sets it to analysis.getReleasedDate(),
   * falling back to getStartedDate(). A reader following the specification would
   * get the release time: a plausible timestamp, hours wrong, with nothing
   * failing. The real value is on the Specimen the report references.
   *
   * Null-safe on purpose. OpenELIS calls specimen.setCollection()
   * unconditionally — unlike setReceivedTime(), which it guards — so a specimen
   * with no collection date still arrives carrying a `collection` element built
   * around a null. Testing for the element is not enough; the DATE has to be
   * there.
   */
  private async collectedAt(report: FhirResource, observations: IObservation[]): Promise<string | null> {
    const ids = new Set<string>();
    for (const reference of asArray(report.specimen)) {
      const id = idOf(reference);
      if (id) ids.add(id);
    }
    // The Observation names the same Specimen; a useful second route.
    for (const observation of observations) {
      const id = idOf(observation.content.specimen);
      if (id) ids.add(id);
    }

    for (const id of ids) {
      const specimen = await this.received.get('Specimen', id);
      const collected = (specimen?.content.collection as Record<string, unknown> | undefined)
        ?.collectedDateTime;
      if (typeof collected === 'string' && collected.trim().length > 0) return collected;
    }

    return null;
  }

  private releasedAt(report: FhirResource): string {
    if (typeof report.issued === 'string' && report.issued.trim()) return report.issued;
    const effective = report.effectiveDateTime;
    if (typeof effective === 'string' && !Number.isNaN(new Date(effective).getTime())) return effective;
    return new Date().toISOString();
  }

  private reportName(report: FhirResource): string | null {
    const code = report.code as Record<string, unknown> | undefined;
    if (!code) return null;
    const text = code.text;
    if (typeof text === 'string' && text.trim()) return text;
    const display = asArray(code.coding).map((c) => c.display).find((d) => typeof d === 'string' && d.trim());
    return typeof display === 'string' ? display : null;
  }

  private async forward(
    report: FhirResource,
    tracked: TrackedOrder,
    status: string,
    receivedAt: string | null,
  ): Promise<void> {
    const reportId = report.id as string;
    const resultRef = `DiagnosticReport/${reportId}`;
    const retracted = status === RETRACTED_STATUS;

    // Every analyte in the report, not just the first. A DiagnosticReport may
    // reference several Observations — eight for a full blood count. An earlier
    // version took element zero and dropped the rest, which lost seven results
    // with nothing recording the loss. See db/his/016_result_components.sql.
    const { resolved: observations, missing } = retracted
      ? { resolved: [] as IObservation[], missing: 0 }
      : await this.observationsOf(report);

    // RESOLVED BEFORE CLAIMED, and the order is the point.
    //
    // OpenELIS pushes a report's Observations in separate deliveries, so a panel
    // routinely arrives incomplete and completes moments later. The forward is
    // claimed once per (report, version), so publishing a partial panel would be
    // final: the analytes still in flight would arrive to find the version
    // already forwarded and be dropped for ever. Waiting costs one sweep;
    // claiming early costs the result.
    //
    // The wait is bounded by the same window as correlation. Past it, a
    // laboratory result that exists is worth more to a clinician than a complete
    // one that never comes — so forward what resolved and say loudly what did
    // not.
    if (missing > 0) {
      const waitedMs = Date.now() - new Date(receivedAt ?? Date.now()).getTime();
      if (waitedMs <= config.correlationRetryMinutes * 60_000) {
        logger.info(
          `${resultRef} references ${missing} Observation(s) that have not arrived ` +
            `(${Math.round(waitedMs / 1000)}s old); leaving it for the next sweep rather than ` +
            'forwarding a partial report',
        );
        return; // deliberately NOT marked processed
      }

      logger.warn(
        `${resultRef} still references ${missing} unresolvable Observation(s) after ` +
          `${Math.round(waitedMs / 60_000)} min; forwarding the ${observations.length} that did ` +
          'arrive. The report in the HIS is INCOMPLETE.',
      );

      await this.deadLetters.record(
        'fhir:Observation',
        `${resultRef} references ${missing} Observation(s) that never arrived; forwarded ` +
          `${observations.length} of ${observations.length + missing} analytes to order ` +
          tracked.orderNumber,
        JSON.stringify(report),
        tracked.correlationId,
      );
    }

    // OpenELIS increments meta.versionId when it corrects a result, so the
    // version is part of the identity of what we are forwarding. Absent a
    // version we fall back to "1", which reproduces the old
    // one-forward-per-report behaviour rather than forwarding endlessly.
    const meta = report.meta as Record<string, unknown> | undefined;
    const versionId = typeof meta?.versionId === 'string' ? meta.versionId : '1';

    if (!(await this.forwarded.claim(resultRef, versionId, tracked.orderId))) {
      logger.info(
        `${resultRef} version ${versionId} already forwarded for order ${tracked.orderNumber}; skipping`,
      );
      await this.received.markProcessed('DiagnosticReport', reportId);
      return;
    }

    // The report-level fields stay exactly as they were, taken from the first
    // component. They are the compatibility view: a consumer that knows nothing
    // about panels still gets the answer it always got, and every existing
    // assertion about resultValue keeps holding.
    //
    // Forwarding the old number alongside a retracted status would invite a
    // reader to keep using it. The retraction is the whole message.
    const flat = retracted
      ? { value: null, unit: null, referenceRange: null, interpretation: null, interpretationCode: null }
      : flatten(observations[0] ?? null, report);

    const correlationId = tracked.correlationId ?? randomUUID();
    const reportName = this.reportName(report);

    const message = {
      eventId: randomUUID(),
      eventType: 'lab.result.released',
      occurredAt: new Date().toISOString(),
      correlationId,
      orderNumber: tracked.orderNumber,
      // The mandatory back-reference: the HIS copy always points at the OpenELIS
      // record that remains the source of truth.
      openelisResultRef: resultRef,
      testCode: tracked.testCode,
      testName: reportName,
      resultValue: flat.value,
      resultUnit: flat.unit,
      referenceRange: flat.referenceRange,
      interpretation: flat.interpretation,
      // When the LABORATORY says the specimen was drawn. For an outpatient this
      // is the only record of it that exists anywhere.
      labCollectedAt: await this.collectedAt(report, observations),
      // The code travels beside the label so the receiving system can
      // distinguish critically abnormal (AA/HH/LL) from merely abnormal (A/H/L)
      // without pattern-matching on the laboratory's wording.
      interpretationCode: flat.interpretationCode,
      resultStatus: status,
      releasedAt: this.releasedAt(report),
      // The whole report, analyte by analyte, in the order the laboratory
      // released them. Empty for a retraction — there is no value to carry, only
      // the withdrawal — and one element for the ordinary single-analyte result,
      // whose values equal the flat fields above.
      observations: observations.map((observation, position) => {
        const component = flatten(observation, report);
        return {
          position,
          code: analyteCode(observation.content),
          // The report's own name is a fallback ONLY when there is one analyte,
          // where the report and the analyte are the same thing. For a panel it
          // names the panel, and labelling eight components "Full blood count"
          // would make them indistinguishable — worse than leaving the name
          // unstated.
          name: analyteName(observation.content) ?? (observations.length === 1 ? reportName : null),
          value: component.value,
          unit: component.unit,
          referenceRange: component.referenceRange,
          interpretation: component.interpretation,
          interpretationCode: component.interpretationCode,
        };
      }),
    };

    await eventPublisher.publish(
      config.kafka.topics.resultReleased,
      tracked.orderNumber,
      message,
      correlationId,
    );
    await this.received.markProcessed('DiagnosticReport', reportId);

    logger.info(
      `Forwarded released result ${resultRef} for order ${tracked.orderNumber}: ` +
        `${flat.value ?? ''} ${flat.unit ?? ''}`.trimEnd(),
    );

    await this.closeTaskIfStillOutstanding(tracked);
  }

  /**
   * A result came back, so the laboratory has done the work — whatever the
   * acknowledgement did or did not do.
   *
   * Normally there is nothing to close here: OpenELIS acknowledged the Task
   * when it imported the order, long before the result, and the guarded UPDATE
   * matches nothing. This is for the case where the acknowledgement was LOST —
   * upstream defect 01, or a container restarted mid-write — and the Task is
   * still sitting in `requested` being re-offered to the laboratory on every
   * single poll, for ever, for an order that is already finished.
   *
   * Closing it is safe in a way that closing it on a timer would not be: the
   * evidence is a released result correlated to this exact order, not a guess
   * about how long is too long. And it is deliberately LOUD, because a result
   * without an acknowledgement means the order path failed silently even though
   * the result path worked — the operator needs to know the acknowledgement is
   * being lost, not just have the symptom cleaned up underneath them.
   */
  private async closeTaskIfStillOutstanding(tracked: TrackedOrder): Promise<void> {
    try {
      if (!(await this.store.completeTaskIfOutstanding(tracked.fhirTaskId))) return;

      await this.tracking.setTaskStatus(tracked.fhirTaskId, 'completed');
      await this.store.releaseDeliveryLease(tracked.fhirTaskId);

      logger.warn(
        `Order ${tracked.orderNumber} was resulted while its Task was still ` +
          `'${tracked.taskStatus}' — the laboratory never acknowledged the order it evidently ` +
          'imported. Closing the Task as completed so it stops being re-offered on every poll. ' +
          'Check bridge.delivery_leases.deliveries for how many times it was handed over, and ' +
          'the OpenELIS log around the import for why the acknowledgement was lost.',
      );
    } catch (error) {
      // Never let this cost the result. The forward has already been published
      // and claimed; a failure to tidy the Task is a loop to fix later, not a
      // reason to redeliver a result the HIS has.
      logger.error(
        `Could not close Task ${tracked.fhirTaskId} after forwarding its result: ` +
          (error as Error).message,
      );
    }
  }
}
