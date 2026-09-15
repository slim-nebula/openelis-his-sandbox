import { randomUUID } from 'node:crypto';
import type { Consumer, EachMessagePayload } from 'kafkajs';
import { kafka } from '@config/kafka.js';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { eventPublisher } from '@config/kafka.js';
import type { CatalogueModel } from '@modules/catalogue/models/catalogue.model.js';
import type { ICatalogueEntry } from '@modules/catalogue/types/catalogue.types.js';
import type { DeadLetterModel } from '@shared/models/dead-letter.model.js';
import type { EventClaimModel } from '@shared/models/event-claim.model.js';
import type { HisApiClient } from './clients/his-api.client.js';
import type { OrderTrackingModel } from './models/order-tracking.model.js';
import { mapOrder } from './order.mapper.js';
import type { IHisOrder, IOrderCreatedEvent } from './types/order.types.js';

/**
 * Consumes lab.order.created, fetches the full order from the HIS, maps it to
 * FHIR and publishes it for OpenELIS to poll.
 *
 * Duplicate deliveries are absorbed by a claim on the event key, and the
 * resource ids are derived deterministically from the order id, so even a
 * replayed event produces an update rather than a second order.
 */
export class OrderConsumer {
  private consumer: Consumer | null = null;
  private running = false;

  constructor(
    private readonly his: HisApiClient,
    private readonly tracking: OrderTrackingModel,
    private readonly catalogue: CatalogueModel,
    private readonly claims: EventClaimModel,
    private readonly deadLetters: DeadLetterModel,
  ) {}

  async start(): Promise<void> {
    if (this.running) return;

    const consumer = kafka.consumer({
      // The literal group name, not an environment variable, matching the .NET
      // service. `make smoke` asserts a group containing "bridge" is registered
      // with the broker, and a per-deployment name would turn that into a test
      // of the deployment rather than of the service.
      groupId: config.kafka.consumerGroup,
      sessionTimeout: 30_000,
    });

    await consumer.connect();
    // fromBeginning matters on a FIRST run: the .NET consumer used
    // AutoOffsetReset.Earliest, so an order published before the bridge ever
    // started is still delivered rather than skipped. Once the group has
    // committed offsets this has no effect.
    await consumer.subscribe({ topic: config.kafka.topics.orderCreated, fromBeginning: true });

    this.consumer = consumer;
    this.running = true;

    // autoCommit commits only AFTER eachMessage resolves, so throwing leaves the
    // offset uncommitted and Kafka redelivers — which is the .NET manual-commit
    // behaviour without the manual commit.
    await consumer.run({ eachMessage: (payload) => this.handle(payload) });

    logger.info(`Bridge consuming ${config.kafka.topics.orderCreated} from ${config.kafka.brokers.join(',')}`);
  }

  async stop(): Promise<void> {
    this.running = false;
    if (!this.consumer) return;
    try {
      await this.consumer.disconnect();
    } catch {
      // Shutting down; the broker will time the member out regardless.
    }
    this.consumer = null;
  }

  private async handle({ topic, partition, message }: EachMessagePayload): Promise<void> {
    const raw = message.value?.toString();

    let event: IOrderCreatedEvent;
    try {
      if (!raw?.trim()) throw new Error('Empty lab.order.created payload');
      event = JSON.parse(raw) as IOrderCreatedEvent;
      if (!event.orderId) throw new Error('lab.order.created payload carries no orderId');
    } catch (error) {
      // Unparseable now means unparseable forever. Record it and RETURN — which
      // commits past it — because throwing would redeliver it indefinitely and
      // block every order behind it on this partition.
      logger.error(
        `Poison message on ${topic} at offset ${message.offset}; dead-lettering: ${(error as Error).message}`,
      );
      await this.deadLetters.record(
        topic,
        `Unparseable lab.order.created payload at offset ${message.offset}: ${(error as Error).message}`,
        null,
        null,
      );
      return;
    }

    const headerCorrelation = message.headers?.['X-Correlation-ID']?.toString();
    const correlationId = event.correlationId ?? headerCorrelation ?? randomUUID();

    const eventKey = event.eventId ?? `${topic}:${partition}:${message.offset}`;
    if (!(await this.claims.claim(eventKey, 'lab.order.created'))) {
      logger.info(`Duplicate lab.order.created ${eventKey} ignored`);
      return;
    }

    try {
      await this.process(event, correlationId);
    } catch (error) {
      // Release the claim so redelivery genuinely retries rather than being
      // swallowed as a duplicate, then rethrow to leave the offset uncommitted.
      await this.claims.release(eventKey);
      throw error;
    }
  }

  /** Dead-letter and tell the HIS, in the one shape every refusal here uses. */
  private async refuse(
    event: IOrderCreatedEvent,
    order: IHisOrder | null,
    reason: string,
    correlationId: string,
  ): Promise<void> {
    await this.deadLetters.record(
      config.kafka.topics.orderCreated,
      reason,
      JSON.stringify(event),
      correlationId,
    );

    await eventPublisher.publish(
      config.kafka.topics.orderFailed,
      order?.orderNumber ?? event.orderNumber,
      {
        eventId: randomUUID(),
        correlationId,
        orderId: order?.orderId ?? event.orderId,
        orderNumber: order?.orderNumber ?? event.orderNumber,
        status: 'FAILED',
        detail: reason,
      },
      correlationId,
    );
  }

  private async process(event: IOrderCreatedEvent, correlationId: string): Promise<void> {
    let order: IHisOrder;
    try {
      order = await this.his.fetchOrder(event.orderId, correlationId);
    } catch (error) {
      await this.refuse(
        event,
        null,
        `Bridge could not load order context: ${(error as Error).message}`,
        correlationId,
      );
      return;
    }

    if (!order.loincCode?.trim()) {
      await this.refuse(
        event,
        order,
        'Order has no LOINC mapping; OpenELIS cannot resolve a test.',
        correlationId,
      );
      return;
    }

    // Resolve the specimen the way OpenELIS will, BEFORE sending anything.
    //
    // Two different situations, and collapsing them is a mistake worth spelling
    // out, because the first version of this did:
    //
    //   on the menu, no abbreviation  -> REFUSE. We would send a specimen
    //       OpenELIS cannot resolve, and it does not error: it binds the first
    //       test matching the LOINC. A plasma order goes to the serum bench with
    //       nothing logged on either side. This is a stale catalogue and the fix
    //       is a re-sync, so say so.
    //
    //   not on the menu at all        -> SEND IT. The bridge never discovered
    //       this test, so it has no opinion about it, and the laboratory is the
    //       authority on what it accepts. OpenELIS will reject a LOINC it does
    //       not carry, and that rejection travelling back is the drift signal
    //       the integration is built on. Refusing here would substitute our
    //       judgement for the laboratory's and silently delete the whole
    //       rejection path.
    const catalogue = await this.catalogue.all();
    const offering: ICatalogueEntry | undefined = catalogue.find(
      (entry) => entry.loinc === order.loincCode && entry.specimenName === order.specimenType,
    );

    if (offering && !offering.specimenAbbreviation?.trim()) {
      await this.refuse(
        event,
        order,
        `Catalogue offers LOINC ${order.loincCode} on specimen '${order.specimenType}' but holds ` +
          'no sample-type abbreviation for it. OpenELIS would bind the first test matching the ' +
          'code rather than the one ordered. Re-run the catalogue sync.',
        correlationId,
      );
      return;
    }

    // An unknown test splits again, and the two halves are not equally safe.
    //
    // The catalogue is derived from what OpenELIS offers, so if the LOINC is
    // absent from it ENTIRELY, OpenELIS almost certainly does not carry the code
    // either: it cannot first-match what it does not have, and it will reject
    // the order. That is the drift path and it must stay open.
    //
    // But if the LOINC is present under a DIFFERENT specimen, we know for a fact
    // OpenELIS carries this code — possibly on several tests. Sending it with no
    // sample-type coding is then precisely the input that makes addToTestOrPanel
    // bind alltests.get(0). Refuse: we would be handing the laboratory a
    // confident answer to a question we could not answer.
    if (!offering) {
      const loincIsKnown = catalogue.some((entry) => entry.loinc === order.loincCode);

      if (loincIsKnown) {
        await this.refuse(
          event,
          order,
          `LOINC ${order.loincCode} is offered by the laboratory, but not on specimen ` +
            `'${order.specimenType}'. Sending it without a resolvable sample type would let ` +
            'OpenELIS bind the first test carrying the code. Re-run the catalogue sync, or order ' +
            'a specimen the laboratory accepts for this test.',
          correlationId,
        );
        return;
      }

      logger.warn(
        `Order ${order.orderNumber} is for LOINC ${order.loincCode} on '${order.specimenType}', ` +
          'a code the laboratory does not offer at all. Sending without a sample-type coding so ' +
          'the laboratory can reject it, which is the drift signal.',
      );
    }

    const mapped = mapOrder(
      order,
      config.labOwnerReference,
      config.labOwnerName,
      offering?.specimenAbbreviation ?? null,
    );

    await this.tracking.saveOrder(
      {
        orderId: order.orderId,
        orderNumber: order.orderNumber,
        patientId: order.patient.patientId,
        testCode: order.testCode,
        loincCode: order.loincCode,
        fhirTaskId: mapped.task.id as string,
        fhirServiceRequestId: mapped.serviceRequest.id as string,
        fhirPatientId: mapped.patient.id as string,
        fhirSpecimenId: mapped.specimen.id as string,
        taskStatus: 'requested',
        attempts: 0,
        correlationId,
      },
      mapped.all,
    );

    logger.info(
      `Published FHIR Task ${mapped.task.id} for order ${order.orderNumber} ` +
        `(LOINC ${order.loincCode}); awaiting OpenELIS poll`,
    );

    await eventPublisher.publish(
      config.kafka.topics.orderSent,
      order.orderNumber,
      {
        eventId: randomUUID(),
        correlationId,
        orderId: order.orderId,
        orderNumber: order.orderNumber,
        status: 'SENT_TO_LIS',
        detail: `FHIR Task ${mapped.task.id} published for OpenELIS`,
      },
      correlationId,
    );
  }
}
