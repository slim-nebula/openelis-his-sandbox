import http from 'node:http';
import app from './app.js';
import { config } from '@config/env.js';
import { pool, waitForDatabase } from '@config/db.js';
import { logger, startLogShipping, stopLogShipping } from '@config/logger.js';
import { eventPublisher } from '@config/kafka.js';
import { ConsulRegistration } from '@config/consul.js';
import { closeRedis } from '@config/redis.js';
import { createMtlsServer } from '@config/mtls.js';
import { announceFhirPeerPolicy } from '@core/middleware/fhir-peer-guard.js';
import OrdersContainer from '@modules/orders/containers/orders.container.js';
import ResultsContainer from '@modules/results/containers/results.container.js';

const consul = new ConsulRegistration();

/**
 * Two listeners, one application.
 *
 * ASP.NET needed Kestrel configured with two endpoints; Express is just a
 * request handler, so the same app is handed to an http server on 8080 and —
 * when mutual TLS is on — an https server on 8443. Nothing in a route needs to
 * know which one it arrived on, except the FHIR peer guard, which reads
 * req.socket.localPort deliberately.
 *
 * 8080 is the estate-facing port: Consul's check, Prometheus, his-api reading
 * the cached catalogue, operators on /ops. 8443 is OpenELIS's.
 */
const start = async (): Promise<void> => {
  // NOT awaited, unlike his-api's. Log shipping is the one subsystem whose
  // failure must never delay anything: KafkaJS's connect() retries with backoff
  // for the better part of a minute before it rejects, so awaiting it turns a
  // broker that is merely slow to start into a bridge that is not yet serving
  // OpenELIS's poll. The .NET service it replaces had the same property for the
  // same reason — its log producer was built, not connected, at startup.
  //
  // Console logging works throughout, which is what an incident actually needs.
  void startLogShipping();

  await waitForDatabase();

  announceFhirPeerPolicy();

  const plaintext = http.createServer(app);
  await new Promise<void>((resolve) => plaintext.listen(config.port, resolve));
  logger.info(`${config.serviceName} listening on ${config.port}`);

  // The same app, on the port OpenELIS is configured to reach. It binds whether
  // or not the certificates are on disk yet: a missing file is a handshake that
  // does not complete, never a process that will not start.
  const mtls = createMtlsServer(app);
  if (mtls) {
    await new Promise<void>((resolve) => mtls.listen(config.mtls.port, resolve));
    logger.info(`${config.serviceName} serving mutually authenticated /fhir on ${config.mtls.port}`);
  }

  try {
    await eventPublisher.connect();
  } catch (error) {
    // Survivable. The bridge can still serve OpenELIS's poll and accept result
    // pushes; what it cannot do is tell the HIS about them, and that work is
    // retried rather than lost.
    logger.error(`Kafka producer failed to connect: ${(error as Error).message}`);
  }

  // Started AFTER the producer, because the first thing it does on a refusal is
  // publish lab.order.failed. Started BEFORE Consul registration for the same
  // reason the listener is: a service in the catalogue should already be doing
  // its job.
  //
  // A broker that is down means this throws; the bridge still serves OpenELIS's
  // poll and accepts result pushes, which is the half of the integration that
  // does not need Kafka. KafkaJS reconnects on its own once the broker returns.
  try {
    await OrdersContainer.consumer.start();
  } catch (error) {
    logger.error(`Order consumer failed to start: ${(error as Error).message}`);
  }

  // The return path. Both are timer loops over the inbound mirror rather than
  // work done inline on OpenELIS's push, because the pieces of one result arrive
  // in several deliveries and in no guaranteed order — a report whose
  // Observations are still in flight is left for the next sweep.
  ResultsContainer.correlator.start();
  ResultsContainer.progress.start();

  await consul.register();

  const shutdown = async (signal: string): Promise<void> => {
    logger.info(`${signal} received; shutting down`);
    // Deregister FIRST — stop receiving traffic before closing anything.
    await consul.deregister();

    // Leave the consumer group before the producer goes, so an in-flight order
    // finishes publishing rather than being cut off mid-handler and redelivered.
    await OrdersContainer.consumer.stop();
    ResultsContainer.correlator.stop();
    ResultsContainer.progress.stop();

    // Closed and DRAINED, with a ceiling. close() stops new connections and
    // resolves once the in-flight ones finish, so an import that is halfway
    // through writing an order is not cut in two by a redeploy. The timeout is
    // what stops a hung connection holding the shutdown open for ever — Docker
    // would send SIGKILL at 10s regardless, and a clean exit reads better in
    // the logs than a killed one.
    const close = (server: { close: (cb: () => void) => void } | null): Promise<void> =>
      server ? new Promise<void>((resolve) => server.close(() => resolve())) : Promise.resolve();

    await Promise.race([
      Promise.all([close(plaintext), close(mtls)]),
      new Promise((resolve) => setTimeout(resolve, 5000)),
    ]);

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
