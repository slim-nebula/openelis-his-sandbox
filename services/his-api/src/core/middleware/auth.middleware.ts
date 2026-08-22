import jwt from 'jsonwebtoken';
import type { NextFunction, Request, Response } from 'express';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { redis } from '@config/redis.js';
import { authChecks } from '@config/metrics.js';

/**
 * The estate's authentication, as `patient-service` performs it: verify an
 * HS256 token signed by IAM, then confirm the session still exists in Redis,
 * and continue without that confirmation if Redis cannot be reached.
 *
 * Three things here are deliberately not what the estate's copies do. Each is
 * explained where it happens, and all three are in docs/security.md.
 */

declare module 'express-serve-static-core' {
  interface Request {
    user?: AuthenticatedUser;
  }
}

export interface AuthenticatedUser {
  usr_id: string;
  usr_name: string;
  usr_full_name: string;
  group_names: string[];
  group_ids: number[];
  business_unit_ids: number[];
  /** True when Redis could not be consulted and the session went unverified. */
  degraded: boolean;
}

interface JwtPayload {
  usr_id: string | number;
  usr_name?: string;
  usr_full_name?: string;
  group_names?: string[];
  group_ids?: number[];
  business_unit_ids?: number[];
}

const unauthorized = (res: Response, message: string): void => {
  res.status(401).json({ status: false, message, data: null });
};

/**
 * Whether the last revocation check could reach Redis, so an outage is reported
 * once at each edge rather than once per request.
 *
 * An outage is exactly when request volume does not drop, and the estate's
 * middleware logs a warning inside the per-request catch block. At any real
 * rate that is thousands of identical lines a minute, on a Kafka topic shared
 * with every other service — the same failure mode the framework log filter
 * exists to prevent (docs/platform-integration.md, §3).
 */
let revocationReachable = true;

const bearerFrom = (header: string | undefined): string | undefined => {
  if (!header) return undefined;
  const [scheme, value] = header.split(' ');
  if (!value || scheme?.toLowerCase() !== 'bearer') return undefined;
  return value.trim() || undefined;
};

export const authenticateUser = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  // Fail closed. Without a secret there is no way to tell a real token from one
  // someone wrote, so the only safe answer is that authentication is unavailable
  // — never "no secret configured, therefore everyone passes".
  if (!config.auth.jwtSecret) {
    logger.error(`Refused ${req.method} ${req.originalUrl}: JWT_SECRET is not set`);
    res.status(503).json({
      status: false,
      message: 'Authentication is not configured on this service.',
      data: null,
    });
    return;
  }

  const token = bearerFrom(req.headers.authorization);
  if (!token) {
    unauthorized(res, 'Authorization token is required');
    return;
  }

  let payload: JwtPayload;
  try {
    // Difference 1: the algorithm is pinned.
    //
    // `jwt.verify` without `algorithms` accepts any algorithm the given key can
    // verify. For a string secret that is the HMAC family only, so this is not
    // the classic algorithm-confusion hole — but pinning costs one line and
    // removes the question entirely, including for whoever later changes the
    // key type to a public key and does not think about it.
    payload = jwt.verify(token, config.auth.jwtSecret, {
      algorithms: ['HS256'],
    }) as JwtPayload;
  } catch {
    // Forged, altered, or expired. The token is never logged — a rejected
    // credential here is often a valid credential for somewhere else.
    unauthorized(res, 'Invalid or expired token');
    return;
  }

  if (payload.usr_id === undefined || payload.usr_id === null || payload.usr_id === '') {
    unauthorized(res, 'Invalid token structure');
    return;
  }

  const userId = String(payload.usr_id);
  let degraded = false;

  try {
    const session = await redis.hget(`user:${userId}`, 'token');

    if (!revocationReachable) {
      logger.info('Redis reachable again — token revocation is being enforced');
      revocationReachable = true;
    }

    // Redis answered, and says this session is gone: logged out, password
    // changed, or the 24h session TTL expired.
    if (!session || session !== token) {
      authChecks.labels('revoked').inc();
      unauthorized(res, 'Session ended or token revoked');
      return;
    }

    authChecks.labels('allowed').inc();
  } catch (error) {
    // Difference 2: the outage is logged at its edges, not per request.
    degraded = true;
    authChecks.labels('degraded').inc();

    if (revocationReachable) {
      revocationReachable = false;
      logger.warn(
        `Redis unreachable (${(error as Error).message}) — continuing in degraded ` +
          'authentication mode: signatures are still verified, revocation is not enforced. ' +
          'Logouts will not take effect until Redis returns.',
      );
    }
  }

  // Difference 3: whether the session was verified is carried forward.
  //
  // The estate's version cannot tell, afterwards, which requests were served
  // without a revocation check. Recording it on the request means the metric
  // above can be alerted on, and a route that should refuse to run unverified
  // is able to say so.
  req.user = {
    usr_id: userId,
    usr_name: payload.usr_name ?? '',
    usr_full_name: payload.usr_full_name ?? '',
    group_names: payload.group_names ?? [],
    group_ids: payload.group_ids ?? [],
    business_unit_ids: payload.business_unit_ids ?? [],
    degraded,
  };

  next();
};

/**
 * Requires one of IAM's group names on the token.
 *
 * Coarse on purpose. The estate does real authorisation with Casbin against
 * policies IAM owns, and a second, different-shaped permission model in a
 * reference service would be a worse example than an obviously partial one.
 * Configured empty, this allows any authenticated user — the sandbox's default,
 * because it has no IAM to define groups.
 */
export const requireGroup =
  (group: string) =>
  (req: Request, res: Response, next: NextFunction): void => {
    if (!group) {
      next();
      return;
    }

    if (!req.user?.group_names.includes(group)) {
      logger.warn(
        `Refused ${req.method} ${req.originalUrl} for user ${req.user?.usr_id}: not in group ${group}`,
      );
      res.status(403).json({
        status: false,
        message: `This endpoint requires membership of ${group}.`,
        data: null,
      });
      return;
    }

    next();
  };
