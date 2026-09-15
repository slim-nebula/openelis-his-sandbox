import { Kafka, Partitioners, type Producer } from 'kafkajs';
import { config } from './env.js';
import { logger } from './logger.js';

const kafka = new Kafka({
  clientId: config.serviceName,
  brokers: config.kafka.brokers,
});

/**
 * Publishes domain events.
 *
 * Three settings that are not KafkaJS defaults, and matter:
 *
 *   idempotent            without it a retry can land AFTER a message produced
 *                         later, so an older order status can overwrite a newer
 *                         one. It also pins acks=-1 and bounds in-flight
 *                         requests, which is what makes ordering hold.
 *   send() rejects        a failed publish must not look like a successful one.
 *                         Fire-and-forget is a decision for the CALLER to make
 *                         per call site, not a property baked into transport:
 *                         some events are best-effort, and some are an order
 *                         for a patient.
 *   legacy partitioner    keys already in use must keep hashing to the same
 *                         partition, or per-order ordering breaks silently on
 *                         upgrade.
 */
class EventPublisher {
  private producer: Producer | null = null;

  async connect(): Promise<void> {
    this.producer = kafka.producer({
      idempotent: true,
      maxInFlightRequests: 5,
      createPartitioner: Partitioners.LegacyPartitioner,
    });
    await this.producer.connect();
    logger.info(`Kafka producer connected to ${config.kafka.brokers.join(',')}`);
  }

  /**
   * Publishes an already-serialised payload.
   *
   * The outbox stores the exact bytes committed alongside the order, so the
   * relay sends those rather than re-serialising and risking a different shape
   * from the one the transaction agreed to.
   */
  async publishRaw(topic: string, key: string, json: string, correlationId: string): Promise<void> {
    if (!this.producer) throw new Error('Kafka producer is not connected');

    await this.producer.send({
      topic,
      messages: [{ key, value: json, headers: { 'X-Correlation-ID': correlationId } }],
    });
    logger.info(`Published ${topic} key=${key} correlation=${correlationId}`);
  }

  async publish(topic: string, key: string, payload: unknown, correlationId: string): Promise<void> {
    await this.publishRaw(topic, key, JSON.stringify(payload), correlationId);
  }

  async disconnect(): Promise<void> {
    if (!this.producer) return;
    await this.producer.disconnect();
    this.producer = null;
  }
}

export const eventPublisher = new EventPublisher();
export { kafka };
