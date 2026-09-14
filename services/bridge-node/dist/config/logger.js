import winston from 'winston';
import { Writable } from 'node:stream';
import { Kafka, logLevel } from 'kafkajs';
import { config } from './env.js';
/**
 * Console plus the estate's shared Kafka `logs` topic, in the envelope every
 * other service writes: { service, level, message, timestamp }.
 *
 * Console stays because `docker logs bridge` must keep working during an
 * incident, which is exactly when the log topic is least trustworthy.
 *
 * Three properties the Kafka transport has to have:
 *
 *   * It never blocks a request. Logging sits on the hot path of everything, so
 *     a slow broker must not become a slow API — this producer is fire and
 *     forget, and a failure to send is dropped rather than awaited.
 *   * It never logs. Reporting a send failure through winston would write
 *     another line, which sends, which fails. Failures go to stderr, once per
 *     distinct reason.
 *   * It ships application logs only. The topic is SHARED with every service in
 *     the estate, so the question is not "is this worth logging" but "is this
 *     worth putting on everyone's bus".
 *
 * That last point is a measured constraint rather than taste. The .NET service
 * this replaces had to filter ASP.NET's per-request lines explicitly: four
 * Information lines per request, with a Consul check every 10s and a Docker
 * healthcheck alongside it, produced ~2,800 messages in five minutes, none of
 * them about a patient. `make smoke` pins it — sixteen /health requests across
 * bridge and his-api must produce no more than eight log lines.
 *
 * Express logs nothing per request on its own, so the fix here is simply never
 * to add a request logger. Do not reach for morgan.
 */
let producer = null;
const reported = new Set();
const reportOnce = (message) => {
    if (reported.has(message))
        return;
    reported.add(message);
    process.stderr.write(`[kafka-logger] ${message}\n`);
};
const kafkaStream = new Writable({
    write(chunk, _encoding, callback) {
        const line = chunk.toString().trim();
        if (!line || !producer)
            return callback();
        producer
            .send({
            topic: config.kafka.topics.logs,
            messages: [
                {
                    key: config.serviceName,
                    value: JSON.stringify({
                        service: config.serviceName,
                        level: 'info',
                        message: line,
                        timestamp: new Date().toISOString(),
                    }),
                },
            ],
        })
            .catch((error) => reportOnce(`send failed: ${error.message}`));
        // Called immediately, not after the send resolves: the request that
        // produced this line must not wait for a broker.
        callback();
    },
});
export const logger = winston.createLogger({
    level: 'info',
    defaultMeta: { service: config.serviceName },
    format: winston.format.combine(winston.format.timestamp(), winston.format.printf(({ level, message, timestamp }) => `${timestamp} ${level}: ${message}`)),
    transports: [new winston.transports.Console(), new winston.transports.Stream({ stream: kafkaStream })],
});
/** Connects the log shipper. Failure is survivable: console logging continues. */
export const startLogShipping = async () => {
    try {
        const kafka = new Kafka({
            clientId: `${config.serviceName}-logger`,
            brokers: config.kafka.brokers,
            logLevel: logLevel.NOTHING,
        });
        // Its own producer, deliberately. Sharing the domain-event producer would
        // mean log delivery competing with orders for the same in-flight budget,
        // and would couple the two failure modes.
        //
        // Assigned only AFTER connect resolves. Assigning first leaves a window in
        // which the transport has a producer that is not connected yet, and every
        // line logged during startup — which is most of them — fails with "the
        // producer is disconnected". Harmless, but it fills stderr with noise about
        // logging instead of about the service.
        const connecting = kafka.producer();
        await connecting.connect();
        producer = connecting;
    }
    catch (error) {
        reportOnce(`disabled: ${error.message}`);
        producer = null;
    }
};
export const stopLogShipping = async () => {
    if (!producer)
        return;
    try {
        await producer.disconnect();
    }
    catch {
        // Shutting down; nowhere useful to report this.
    }
    producer = null;
};
