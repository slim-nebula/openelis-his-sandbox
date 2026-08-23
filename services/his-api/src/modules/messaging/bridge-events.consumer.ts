import { randomUUID } from 'node:crypto';
import type { Consumer, EachMessagePayload } from 'kafkajs';
import { kafka, eventPublisher } from '@config/kafka.js';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import LabOrdersContainer from '@modules/lab-orders/containers/lab-orders.container.js';
import type {
  IOrderLifecycleMessage,
  IReleasedResultMessage,
  ILabProgressMessage,
} from '@modules/lab-orders/types/lab-order.types.js';

/** A message that can never succeed, however many times it is retried. */
class PoisonMessageError extends Error {}

/**
 * Consumes what the bridge emits: order transmission outcomes and released
 * results.
 *
 * Offsets are committed only after the database write succeeds, so a crash
 * mid-handler replays rather than loses the message — the writes are
 * idempotent, which is what makes that safe.
 *
 * The poison-message path matters as much as the happy one. A payload that
 * cannot be parsed will never parse, so retrying it forever blocks the
 * partition and stalls every well-formed message behind it. Those go to the
 * dead-letter topic and the offset is committed past them.
 */
export class BridgeEventConsumer {
  private consumer: Consumer | null = null;

  async start(): Promise<void> {
    const topics = [
      config.kafka.topics.resultReleased,
      config.kafka.topics.orderSent,
      config.kafka.topics.orderFailed,
      config.kafka.topics.orderProgress,
    ];

    this.consumer = kafka.consumer({
      groupId: config.kafka.consumerGroup,
      sessionTimeout: 30_000,
    });

    await this.consumer.connect();
    for (const topic of topics) {
      await this.consumer.subscribe({ topic, fromBeginning: true });
    }

    // autoCommit is on, but KafkaJS only commits AFTER eachMessage resolves.
    // Throwing therefore leaves the offset uncommitted and the message is
    // redelivered, which is the at-least-once behaviour these handlers rely on.
    await this.consumer.run({
      eachMessage: (payload) => this.handle(payload),
    });

    logger.info(`Subscribed to ${topics.join(', ')}`);
  }

  private async handle({ topic, partition, message }: EachMessagePayload): Promise<void> {
    const correlationId =
      message.headers?.['X-Correlation-ID']?.toString() ??
      message.headers?.['x-correlation-id']?.toString() ??
      randomUUID();

    const raw = message.value?.toString() ?? '';

    try {
      const parsed = this.parse(raw, topic);
      const orders = LabOrdersContainer.labOrderService;

      if (topic === config.kafka.topics.resultReleased) {
        const result = parsed as IReleasedResultMessage;
        await orders.storeResult({
          ...result,
          correlationId: result.correlationId ?? correlationId,
        });
        return;
      }

      // Where the order has got to inside the laboratory. Deliberately not
      // folded into order_status: this is a refinement underneath
      // ACCEPTED_BY_LIS, and the status is a contract the frontend and the
      // suites are written against.
      if (topic === config.kafka.topics.orderProgress) {
        const progress = parsed as ILabProgressMessage;
        await orders.recordProgress(
          progress.orderNumber,
          progress.progress,
          progress.accessionNumber ?? null,
          progress.correlationId ?? correlationId,
        );
        return;
      }

      const lifecycle = parsed as IOrderLifecycleMessage;
      // The bridge reports the LIS's own verdict on lab.order.sent once the
      // Task comes back accepted or rejected, so its status wins where it is
      // one this service recognises.
      const known = ['ACCEPTED_BY_LIS', 'REJECTED_BY_LIS', 'SENT_TO_LIS', 'FAILED'];
      const fallback = topic === config.kafka.topics.orderSent ? 'SENT_TO_LIS' : 'FAILED';
      const status = known.includes(lifecycle.status) ? lifecycle.status : fallback;

      await orders.updateStatus(
        lifecycle.orderNumber,
        status,
        lifecycle.detail ?? null,
        lifecycle.correlationId ?? correlationId,
      );
    } catch (error) {
      if (error instanceof PoisonMessageError) {
        logger.error(
          `Poison message on ${topic} at offset ${message.offset}; dead-lettering: ${error.message}`,
        );
        await this.deadLetter(topic, partition, message.offset, raw, error, correlationId);
        return; // commit past it
      }
      // Transient — database down, broker hiccup. Rethrow so KafkaJS leaves the
      // offset uncommitted and redelivers.
      logger.error(`Failed handling message on ${topic}: ${(error as Error).message}`);
      throw error;
    }
  }

  private parse(raw: string, topic: string): unknown {
    if (!raw.trim()) throw new PoisonMessageError(`Empty payload on ${topic}`);
    try {
      return JSON.parse(raw);
    } catch {
      throw new PoisonMessageError(`Unparseable payload on ${topic}`);
    }
  }

  private async deadLetter(
    topic: string,
    partition: number,
    offset: string,
    payload: string,
    cause: Error,
    correlationId: string,
  ): Promise<void> {
    try {
      await eventPublisher.publish(
        `${topic}.dlq`,
        'unkeyed',
        {
          deadLetteredAt: new Date().toISOString(),
          sourceTopic: topic,
          partition,
          offset,
          reason: cause.message,
          payload,
        },
        correlationId,
      );
    } catch (error) {
      // Never let a DLQ failure stop the consumer: the alternative is a stalled
      // partition, which is strictly worse than a logged loss.
      logger.error(`Could not write to ${topic}.dlq: ${(error as Error).message}`);
    }
  }

  async stop(): Promise<void> {
    if (!this.consumer) return;
    await this.consumer.disconnect();
    this.consumer = null;
  }
}

export const bridgeEventConsumer = new BridgeEventConsumer();
