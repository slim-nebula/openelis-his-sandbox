import { Redis } from 'ioredis';
import { config } from './env.js';
import { logger } from './logger.js';

/**
 * Redis, used for one thing: checking whether a token has been revoked.
 *
 * The estate's services create the client with host, port and nothing else.
 * That is fine while Redis is up. The settings below are all about what happens
 * when it is not — see docs/security.md, "When Redis is down".
 */
export const redis = new Redis({
  host: config.redis.host,
  port: config.redis.port,

  // A revocation check sits in front of every clinical request, so it must
  // never become the slowest thing in that request. 250ms is far above a
  // healthy HGET (sub-millisecond on the same network) and far below anything
  // a clinician would notice.
  connectTimeout: 1000,
  commandTimeout: 250,
  maxRetriesPerRequest: 1,

  // The important one. By default ioredis *queues* commands issued while the
  // connection is down and replays them when it comes back. Combined with the
  // estate's degraded-mode fallback that produces the opposite of what the
  // fallback intends: instead of failing fast and continuing without the
  // check, every request waits in the offline queue for the connection to
  // return. With this false, a command issued while disconnected rejects
  // immediately and the caller reaches its catch block in microseconds.
  enableOfflineQueue: false,

  // Keep trying, with a ceiling. Backing off to minutes would mean revocation
  // stays unenforced long after Redis is healthy again.
  retryStrategy: (attempt) => Math.min(attempt * 200, 5000),
});

/**
 * Whether the client currently believes it can talk to Redis.
 *
 * Read by the auth middleware only to decide whether a failure is worth
 * logging. The decision to allow or deny is never taken from this flag — it is
 * taken from what the command actually did, because a flag can be stale and a
 * result cannot.
 */
export const redisHealth = { available: false };

redis.on('ready', () => {
  if (!redisHealth.available) logger.info('Redis connection established');
  redisHealth.available = true;
});

// ioredis emits `error` on every reconnection attempt, so an outage of any
// length would otherwise put one line per attempt onto the shared logs topic.
// The transition is logged; the retries are not. An unhandled `error` event on
// an EventEmitter is also a process-level throw, so this handler must exist
// whether or not anything is logged from it.
redis.on('error', (error: Error) => {
  if (redisHealth.available) {
    logger.error(`Redis connection lost: ${error.message}`);
  }
  redisHealth.available = false;
});

redis.on('close', () => {
  redisHealth.available = false;
});

export const closeRedis = async (): Promise<void> => {
  try {
    await redis.quit();
  } catch {
    redis.disconnect();
  }
};

export default redis;
