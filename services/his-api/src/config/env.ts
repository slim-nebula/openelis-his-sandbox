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

/**
 * Redis's address, from whichever of the three shapes the estate uses.
 *
 * Worth the twelve lines: the estate's services pass `REDIS_URL` straight into
 * ioredis's `host` field, which is a string. A value of `redis:6379` or
 * `redis://redis:6379` — both of which look correct in a compose file — is then
 * resolved as a *hostname*, fails, and the client never connects. Nothing
 * announces this; the service simply runs permanently in degraded mode.
 */
const redisTarget = (): { host: string; port: number } => {
  const explicitHost = process.env.REDIS_HOST;
  const explicitPort = Number(process.env.REDIS_PORT || '6379');
  if (explicitHost) return { host: explicitHost, port: explicitPort };

  const raw = env('REDIS_URL', 'redis').replace(/^rediss?:\/\//, '');
  const [host, port] = raw.split(':');
  return { host: host || 'redis', port: Number(port) || explicitPort };
};

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

  redis: redisTarget(),

  auth: {
    /**
     * Shared with the estate's IAM service, which signs the tokens this service
     * only ever verifies. HS256 means the verifying key and the signing key are
     * the same string — so every service holding it can also mint tokens. That
     * is a property of the estate's choice, recorded in docs/security.md, not
     * something this service can fix on its own.
     *
     * No fallback. An unset secret makes every protected route answer 503,
     * which is the correct thing to do: the alternative is a service that
     * silently accepts tokens signed with the empty string.
     */
    jwtSecret: env('JWT_SECRET', ''),

    /**
     * The group a token must carry to reach the laboratory endpoints. Group
     * names come from IAM's `group_names` claim.
     */
    labGroup: env('LAB_ORDER_GROUP', ''),
  },

  /**
   * Presented by the bridge on /internal/*, in the header the estate's gateway
   * already uses for service-to-service calls (`x-internal-api-key`).
   */
  internalApiKey: env('INTERNAL_API_KEY', ''),

  /** Guards the endpoints that change what the hospital can order. */
  adminToken: env('HIS_ADMIN_TOKEN', ''),
} as const;
