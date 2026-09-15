import { randomUUID } from 'node:crypto';
import type { Consumer, EachMessagePayload } from 'kafkajs';
import { kafka, eventPublisher } from '@config/kafka.js';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { kafkaConsumerRunning } from '@config/metrics.js';
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
 *
 * STARTING IS ALSO A THING THAT FAILS
 * The first clean run of this stack found the sharpest version of this. The
 * service came up before the topics had been created, `subscribe` failed with
 * "This server does not host this topic-partition", the error was logged, and
 * boot carried on. The process stayed up. /health stayed green. Consul kept the
 * instance in rotation. And no laboratory result would ever have been stored
 * again — with nothing anywhere saying so.
 *
 * Two things follow from that, and neither is optional. Failing to start is
 * retried rather than logged and abandoned; and `kafka_consumer_running`
 * reports whether this instance is actually consuming, because a consumer that
 * never joined its group has no lag for a lag alert to notice.
 */
export class BridgeEventConsumer {
  private consumer: Consumer | null = null;
  private stopping = false;
  private retrying = false;

  private readonly topics = [
    config.kafka.topics.resultReleased,
    config.kafka.topics.orderSent,
    config.kafka.topics.orderFailed,
    config.kafka.topics.orderProgress,
  ];

  /**
   * Never throws. One attempt is awaited so an ordinary boot logs its
   * subscription before the service reports ready; a failure hands over to the
   * background loop instead of taking the service down, because the HTTP API
   * and the outbox are perfectly serviceable without the broker.
   */
  async start(): Promise<void> {
    if (await this.attempt()) return;
    void this.retryUntilRunning();
  }

  private async attempt(): Promise<boolean> {
    if (this.stopping) return false;

    // Declared out here so the catch can close it. A consumer that connected
    // and then failed to subscribe still holds a slot in the group, and leaving
    // it open makes the next attempt wait out a rebalance for no reason.
    let consumer: Consumer | null = null;

    try {
      consumer = kafka.consumer({
        groupId: config.kafka.consumerGroup,
        sessionTimeout: 30_000,
      });

      // A consumer that crashes after a successful start is the same outage as
      // one that never started, so it lands in the same recovery path.
      // `restart: true` means KafkaJS is handling it itself and this must keep
      // its hands off, or two consumers end up in the group.
      consumer.on(consumer.events.CRASH, ({ payload }) => {
        if (payload.restart || this.stopping) return;
        kafkaConsumerRunning.set(0);
        logger.error(
          `Kafka consumer crashed and will not restart itself: ${payload.error.message}`,
        );
        void this.retryUntilRunning();
      });

      await consumer.connect();
      for (const topic of this.topics) {
        await consumer.subscribe({ topic, fromBeginning: true });
      }

      // autoCommit is on, but KafkaJS only commits AFTER eachMessage resolves.
      // Throwing therefore leaves the offset uncommitted and the message is
      // redelivered, which is the at-least-once behaviour these handlers rely on.
      await consumer.run({
        eachMessage: (payload) => this.handle(payload),
      });

      this.consumer = consumer;
      kafkaConsumerRunning.set(1);
      logger.info(`Subscribed to ${this.topics.join(', ')}`);
      return true;
    } catch (error) {
      kafkaConsumerRunning.set(0);
      await consumer?.disconnect().catch(() => undefined);
      logger.error(`Kafka consumer failed to start: ${(error as Error).message}`);
      return false;
    }
  }

  /**
   * Backs off to thirty seconds and stays there. It does not give up: the two
   * things that cause this — a broker that has not finished starting, and
   * topics that do not exist yet — both resolve on their own, and a service
   * that stopped trying would need a human to notice and restart it.
   */
  private async retryUntilRunning(): Promise<void> {
    if (this.retrying) return;
    this.retrying = true;

    let wait = 2_000;
    try {
      while (!this.stopping) {
        await new Promise((resolve) => setTimeout(resolve, wait));
        if (await this.attempt()) {
          logger.info('Kafka consumer recovered and is receiving messages again');
          return;
        }
        wait = Math.min(wait * 2, 30_000);
      }
    } finally {
      this.retrying = false;
    }
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
    // Set first, so the retry loop and the crash handler both stand down rather
    // than reconnecting a consumer during shutdown.
    this.stopping = true;
    kafkaConsumerRunning.set(0);
    if (!this.consumer) return;
    await this.consumer.disconnect();
    this.consumer = null;
  }
}

export const bridgeEventConsumer = new BridgeEventConsumer();
