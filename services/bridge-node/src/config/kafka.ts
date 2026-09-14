import { Kafka, Partitioners, Producer } from 'kafkajs';
import { config } from './env.js';
import { logger } from './logger.js';

const kafka = new Kafka({
  clientId: config.serviceName,
  brokers: config.kafka.brokers,
});

/**
 * Publishes the bridge's lifecycle and result events.
 *
 * Three settings that are not KafkaJS defaults, and matter:
 *
 *   * `idempotent: true` — a producer retry must not append a second copy. The
 *     bridge republishes on redelivery by design, and duplicate result events
 *     would upsert harmlessly but duplicate every audit row downstream.
 *   * `acks: -1` (all) — the event is the only record that an order reached the
 *     laboratory. Acknowledged by one replica that then dies is a lost order.
 *   * `LegacyPartitioner` — keeps key→partition stable with the rest of the
 *     estate. Changing partitioner mid-life reorders a key's history.
 *
 * Every message carries X-Correlation-ID, which is how one order is followed
 * across five services and two databases.
 */
class EventPublisher {
  private producer: Producer | null = null;

  async connect(): Promise<void> {
    const producer = kafka.producer({
      idempotent: true,
      maxInFlightRequests: 5,
      createPartitioner: Partitioners.LegacyPartitioner,
    });
    await producer.connect();
    this.producer = producer;
  }

  async publish(topic: string, key: string, payload: unknown, correlationId: string): Promise<void> {
    if (!this.producer) throw new Error('Kafka producer is not connected');

    await this.producer.send({
      topic,
      messages: [
        {
          key,
          value: JSON.stringify(payload),
          headers: { 'X-Correlation-ID': correlationId },
        },
      ],
    });

    logger.info(`Published ${topic} key=${key} correlation=${correlationId}`);
  }

  async disconnect(): Promise<void> {
    if (!this.producer) return;
    await this.producer.disconnect();
    this.producer = null;
  }
}

export const eventPublisher = new EventPublisher();
export { kafka };
