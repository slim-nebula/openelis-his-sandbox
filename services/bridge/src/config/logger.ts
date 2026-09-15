import winston from 'winston';
import Transport from 'winston-transport';
import { Kafka, Producer, logLevel } from 'kafkajs';
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
 *
 * WHY THIS IS A Transport AND NOT A STREAM, WHICH IS WHAT his-api USES
 *
 * A winston Stream transport receives the FORMATTED line, so the only level
 * available to put in the envelope is a constant. his-api therefore ships every
 * line as level "info" with the real severity embedded in the message text.
 *
 * The .NET service being replaced did not: KafkaLogProvider shipped the real
 * level, and the live topic proves it — sampling the last 25 messages from the
 * running bridge gave 17 `info` and 8 `warn`. Copying his-api's shape here would
 * have been a REGRESSION dressed as consistency: every Loki or Grafana query
 * filtering the bridge's stream on level="warn" would match nothing, silently.
 *
 * A Transport gets the structured `info` object instead, so the level is the
 * real one and `message` is the bare message rather than a line with a
 * timestamp and severity already baked into it.
 */
let producer: Producer | null = null;
const reported = new Set<string>();

const reportOnce = (message: string): void => {
  if (reported.has(message)) return;
  reported.add(message);
  process.stderr.write(`[kafka-logger] ${message}\n`);
};

class KafkaTransport extends Transport {
  override log(info: Record<string, unknown>, callback: () => void): void {
    // Called immediately, not after the send resolves: the request that
    // produced this line must not wait for a broker.
    setImmediate(() => this.emit('logged', info));

    const message = typeof info.message === 'string' ? info.message : String(info.message ?? '');
    if (!message.trim() || !producer) return callback();

    producer
      .send({
        topic: config.kafka.topics.logs,
        messages: [
          {
            key: config.serviceName,
            value: JSON.stringify({
              service: config.serviceName,
              // The real severity, which is the whole reason this is a
              // Transport. winston's own names already match the estate's
              // envelope: info / warn / error.
              level: typeof info.level === 'string' ? info.level : 'info',
              message,
              timestamp: new Date().toISOString(),
            }),
          },
        ],
      })
      .catch((error: Error) => reportOnce(`send failed: ${error.message}`));

    callback();
  }
}

export const logger = winston.createLogger({
  level: 'info',
  defaultMeta: { service: config.serviceName },
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.printf(({ level, message, timestamp }) => `${timestamp} ${level}: ${message}`),
  ),
  // The printf format above writes the formatted line to winston's MESSAGE
  // symbol and leaves `info.message` and `info.level` untouched, so the console
  // gets the human line and the Kafka transport gets the structured fields.
  transports: [new winston.transports.Console(), new KafkaTransport()],
});

/** Connects the log shipper. Failure is survivable: console logging continues. */
export const startLogShipping = async (): Promise<void> => {
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
  } catch (error) {
    reportOnce(`disabled: ${(error as Error).message}`);
    producer = null;
  }
};

export const stopLogShipping = async (): Promise<void> => {
  if (!producer) return;
  try {
    await producer.disconnect();
  } catch {
    // Shutting down; nowhere useful to report this.
  }
  producer = null;
};
