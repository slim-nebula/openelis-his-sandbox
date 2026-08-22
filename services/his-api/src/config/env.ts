import dotenv from 'dotenv';

dotenv.config();

/**
 * Every setting this service reads, in one place.
 *
 * Nothing below has a hardcoded fallback to a real address or credential. Where
 * a default exists it is a compose service name that only resolves inside the
 * sandbox network, so a misconfigured deployment fails to connect rather than
 * quietly connecting to the wrong thing.
 */
const required = (key: string): string => {
  const value = process.env[key];
  if (!value) throw new Error(`${key} is required.`);
  return value;
};

const env = (key: string, fallback: string): string => process.env[key] || fallback;

export const config = {
  serviceName: env('SERVICE_NAME', 'his-api-service'),
  serviceVersion: env('SERVICE_VERSION', '1.0.0'),
  port: Number(env('SERVICE_PORT', '8080')),

  databaseUrl: required('HIS_DATABASE_URL'),

  kafka: {
    brokers: env('KAFKA_BOOTSTRAP', 'kafka:9092').split(','),
    consumerGroup: env('KAFKA_CONSUMER_GROUP', 'his-api'),
    topics: {
      orderCreated: env('TOPIC_ORDER_CREATED', 'lab.order.created'),
      orderSent: env('TOPIC_ORDER_SENT', 'lab.order.sent'),
      orderFailed: env('TOPIC_ORDER_FAILED', 'lab.order.failed'),
      resultReleased: env('TOPIC_RESULT_RELEASED', 'lab.result.released'),
      resultFailed: env('TOPIC_RESULT_FAILED', 'lab.result.failed'),
      logs: env('TOPIC_LOGS', 'logs'),
    },
  },

  consul: {
    host: env('CONSUL_HOST', ''),
    port: Number(env('CONSUL_PORT', '8500')),
    // Lets a deployment override the detected address where the container's own
    // view of itself is not routable.
    advertisedIp: process.env.SERVICE_IP || undefined,
  },

  bridge: {
    // The bridge is reached DIRECTLY, not through the gateway. It is the one
    // container straddling the boundary to OpenELIS, and sending its traffic
    // out to the public edge would widen the path the whole architecture is
    // arranged to keep narrow.
    internalUrl: env('BRIDGE_INTERNAL_URL', 'http://bridge:8080'),
  },

  /** Guards the endpoints that change what the hospital can order. */
  adminToken: env('HIS_ADMIN_TOKEN', ''),
} as const;
