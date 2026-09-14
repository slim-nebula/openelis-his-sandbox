import { Redis } from 'ioredis';
import { config } from './env.js';
import { logger } from './logger.js';
/**
 * The estate's session store, read only — this service never writes to it. It
 * exists so that a token revoked at IAM stops working here too.
 *
 * `enableOfflineQueue: false` is the setting that makes degraded mode actually
 * degrade. ioredis's default is to QUEUE commands issued while disconnected and
 * replay them on reconnect, so a catch-block written to fall back never runs —
 * the command does not fail, it simply never finishes, and every request waits.
 * With the queue off, a command issued while down rejects in microseconds and
 * the fallback is reached. `make auth` asserts the clinical API still answers
 * in under five seconds with Redis stopped.
 *
 * Null when no address is configured: revocation is then not enforced at all,
 * which is stated at startup rather than discovered later.
 */
export const redis = config.redis.host
    ? new Redis({
        host: config.redis.host,
        port: config.redis.port,
        connectTimeout: 1000,
        commandTimeout: 250,
        maxRetriesPerRequest: 1,
        enableOfflineQueue: false,
        retryStrategy: (attempt) => Math.min(attempt * 200, 5000),
    })
    : null;
export const redisHealth = { available: false };
if (redis) {
    // Logged on transitions only. An outage is exactly when request volume does
    // not fall, and this topic is shared with every service in the estate.
    redis.on('ready', () => {
        if (!redisHealth.available)
            logger.info('Redis reachable — token revocation is being enforced');
        redisHealth.available = true;
    });
    redis.on('error', (error) => {
        if (redisHealth.available) {
            logger.warn(`Redis unreachable (${error.message}) — continuing in degraded authentication mode: ` +
                'signatures are still verified, revocation is not enforced.');
        }
        redisHealth.available = false;
    });
    redis.on('close', () => {
        redisHealth.available = false;
    });
}
else {
    logger.warn('No Redis address configured: estate tokens will be accepted on signature alone, ' +
        'and a logout will not revoke access to this service');
}
export const closeRedis = async () => {
    if (!redis)
        return;
    try {
        await redis.quit();
    }
    catch {
        redis.disconnect();
    }
};
