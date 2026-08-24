import app from './app.js';
import { config } from '@config/env.js';
import { logger, startLogShipping, stopLogShipping } from '@config/logger.js';
import { waitForDatabase, pool } from '@config/db.js';
import { closeRedis } from '@config/redis.js';
import { eventPublisher } from '@config/kafka.js';
import { ConsulRegistration } from '@config/consul.js';
import { outboxRelay } from '@modules/messaging/outbox.relay.js';
import { bridgeEventConsumer } from '@modules/messaging/bridge-events.consumer.js';

const consul = new ConsulRegistration();

const start = async (): Promise<void> => {
  await startLogShipping();
  await waitForDatabase();

  const server = app.listen(config.port, () => {
    logger.info(`${config.serviceName} listening on ${config.port}`);
  });

  // Order matters. The producer must be connected before the relay can drain,
  // and the relay must be running before the consumer starts writing statuses
  // back — otherwise the first batch of events queues up behind a producer that
  // is not ready.
  try {
    await eventPublisher.connect();
  } catch (error) {
    // Survivable: orders still commit to the outbox and the relay retries until
    // the broker returns. This is the whole reason the outbox exists.
    logger.error(`Kafka producer failed to connect: ${(error as Error).message}`);
  }

  outboxRelay.start();

  // Does not throw, and does not give up. A first attempt that fails — a broker
  // still starting, topics not yet created — hands over to a background retry
  // rather than logging once and leaving the service permanently deaf.
  await bridgeEventConsumer.start();

  await consul.register();

  const shutdown = async (signal: string): Promise<void> => {
    logger.info(`${signal} received; shutting down`);
    // Deregister FIRST so Consul stops handing this instance to Kong before it
    // stops accepting connections. The other order produces a window in which
    // clients are routed to a server that is closing.
    await consul.deregister();
    outboxRelay.stop();
    server.close();
    await bridgeEventConsumer.stop().catch(() => undefined);
    await eventPublisher.disconnect().catch(() => undefined);
    await stopLogShipping();
    await closeRedis().catch(() => undefined);
    await pool.end().catch(() => undefined);
    process.exit(0);
  };

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
};

void start().catch((error: Error) => {
  logger.error(`Failed to start: ${error.stack ?? error.message}`);
  process.exit(1);
});
