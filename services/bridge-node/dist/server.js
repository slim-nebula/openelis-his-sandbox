import http from 'node:http';
import app from './app.js';
import { config } from './config/env.js';
import { pool, waitForDatabase } from './config/db.js';
import { logger, startLogShipping, stopLogShipping } from './config/logger.js';
import { eventPublisher } from './config/kafka.js';
import { ConsulRegistration } from './config/consul.js';
import { closeRedis } from './config/redis.js';
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
const start = async () => {
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
    const plaintext = http.createServer(app);
    await new Promise((resolve) => plaintext.listen(config.port, resolve));
    logger.info(`${config.serviceName} listening on ${config.port}`);
    try {
        await eventPublisher.connect();
    }
    catch (error) {
        // Survivable. The bridge can still serve OpenELIS's poll and accept result
        // pushes; what it cannot do is tell the HIS about them, and that work is
        // retried rather than lost.
        logger.error(`Kafka producer failed to connect: ${error.message}`);
    }
    await consul.register();
    const shutdown = async (signal) => {
        logger.info(`${signal} received; shutting down`);
        // Deregister FIRST — stop receiving traffic before closing anything.
        await consul.deregister();
        plaintext.close();
        await eventPublisher.disconnect().catch(() => undefined);
        await stopLogShipping();
        await closeRedis().catch(() => undefined);
        await pool.end().catch(() => undefined);
        process.exit(0);
    };
    process.on('SIGTERM', () => void shutdown('SIGTERM'));
    process.on('SIGINT', () => void shutdown('SIGINT'));
};
void start().catch((error) => {
    logger.error(`Failed to start: ${error.stack ?? error.message}`);
    process.exit(1);
});
