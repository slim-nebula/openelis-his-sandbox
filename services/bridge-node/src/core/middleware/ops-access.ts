import { timingSafeEqual } from 'node:crypto';
import jwt from 'jsonwebtoken';
import type { NextFunction, Request, Response } from 'express';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { redis } from '@config/redis.js';
import { problemResponse } from './error.js';

/**
 * Who may call /ops and the catalogue sync.
 *
 * Two credentials are accepted on the same header, and which one a caller uses
 * says what kind of caller it is:
 *
 *   the shared operator token   scripts, `make` targets, the deployment. No
 *                               person is signed in, so there is no user to be.
 *   an estate user token        a human. Issued by IAM at login, checked here
 *                               exactly as the Node services check it.
 *
 * The shared token stays because removing it would mean the deployment needs a
 * user account and a password that never expires, which is worse than a secret
 * held by the deployment alone. The user token is what stops that secret being
 * pasted into a chat window every time someone wants to look at the queue.
 *
 * WHY /ops IS GUARDED AT ALL, WHEN IT ONLY READS
 * `/ops/orders`, `/ops/dead-letters` and `/ops/reconciliation` report which
 * orders are outstanding and which failed, for named patients. That is a
 * description of real people's care, and it does not become public because it
 * is a GET.
 */
declare module 'express-serve-static-core' {
  interface Request {
    principal?: OpsPrincipal;
  }
}

export interface OpsPrincipal {
  userId: string;
  userName: string;
  groups: string[];
  /** True when Redis could not be consulted and the session went unverified. */
  degraded: boolean;
}

interface OpsJwtPayload {
  usr_id?: string | number;
  usr_name?: string;
  group_names?: string[];
}

const bearerFrom = (header: string | undefined): string | undefined => {
  if (!header?.toLowerCase().startsWith('bearer ')) return undefined;
  return header.slice('bearer '.length).trim() || undefined;
};

/**
 * Fixed-time comparison. A plain `===` returns sooner the earlier it finds a
 * difference, which hands the token over one character at a time to anyone
 * patient enough to measure. Length is compared first because timingSafeEqual
 * throws on a mismatch — and comparing lengths leaks only the length.
 */
const matches = (presented: string, expected: string): boolean => {
  const a = Buffer.from(presented);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
};

/**
 * Verifies an estate token: signature, then session.
 *
 * The signature proves IAM issued it and nobody altered it. It cannot express
 * "this person logged out four minutes ago" — a signed token stays valid until
 * it expires, whatever happens in between. The Redis session is what makes a
 * logout take effect now.
 *
 * Redis unreachable is NOT a refusal. A cache outage must not stop a hospital
 * reading its laboratory queue; the cost — a token revoked before the outage
 * works during it — is real, stated, and smaller than the alternative.
 */
const validateUserToken = async (token: string): Promise<OpsPrincipal | null> => {
  if (!config.access.jwtSecret) return null;

  let payload: OpsJwtPayload;
  try {
    // The algorithm is pinned. Without it the library accepts any algorithm the
    // key can verify; for a string secret that is the HMAC family only, so this
    // is not the classic confusion hole — but it costs one line and removes the
    // question for whoever later changes the key type to a public key.
    payload = jwt.verify(token, config.access.jwtSecret, {
      algorithms: ['HS256'],
      clockTolerance: 30,
    }) as OpsJwtPayload;
  } catch {
    // Forged, altered, or expired. The token is never logged — a rejected
    // credential here is often a valid credential for somewhere else.
    return null;
  }

  const userId = payload.usr_id === undefined || payload.usr_id === null ? '' : String(payload.usr_id);
  if (!userId) return null;

  const principal: OpsPrincipal = {
    userId,
    userName: payload.usr_name ?? '',
    groups: payload.group_names ?? [],
    degraded: false,
  };

  if (!redis) return { ...principal, degraded: true };

  try {
    const session = await redis.hget(`user:${userId}`, 'token');
    // Redis answered and the session is gone: logged out, password changed, or
    // the session TTL ran out.
    if (!session || session !== token) return null;
    return principal;
  } catch {
    return { ...principal, degraded: true };
  }
};

export const requireOpsAccess = async (
  req: Request,
  res: Response,
  next: NextFunction,
): Promise<void> => {
  // Fail closed. An endpoint that changes the doctor's test menu must not become
  // world-writable because a deployment forgot a variable — that is precisely
  // the mistake that only shows up once it has been made.
  if (!config.access.adminToken && !config.access.jwtSecret) {
    logger.error(
      `Refused ${req.method} ${req.originalUrl}: neither BRIDGE_ADMIN_TOKEN nor JWT_SECRET is set`,
    );
    problemResponse(res, 503, 'Administrative access is not configured on this bridge.');
    return;
  }

  const peer = req.socket.remoteAddress ?? 'unknown';
  const presented = bearerFrom(req.headers.authorization);

  if (!presented) {
    logger.warn(`Refused ${req.method} ${req.originalUrl} from ${peer}: no bearer token`);
    problemResponse(res, 401, 'A valid bearer token is required for this endpoint.');
    return;
  }

  if (config.access.adminToken && matches(presented, config.access.adminToken)) {
    next();
    return;
  }

  // Not the shared token, so the only remaining possibility is a user.
  const principal = await validateUserToken(presented);
  if (!principal) {
    logger.warn(
      `Refused ${req.method} ${req.originalUrl} from ${peer}: bad, expired or revoked token`,
    );
    problemResponse(res, 401, 'A valid bearer token is required for this endpoint.');
    return;
  }

  if (config.access.opsGroup && !principal.groups.includes(config.access.opsGroup)) {
    logger.warn(
      `Refused ${req.method} ${req.originalUrl} for user ${principal.userId}: ` +
        `not in group ${config.access.opsGroup}`,
    );
    problemResponse(res, 403, `This endpoint requires membership of ${config.access.opsGroup}.`);
    return;
  }

  // Who did it, on every operational action. The shared token cannot answer
  // this question, which is the other reason for accepting user tokens at all.
  logger.info(
    `${req.method} ${req.originalUrl} by user ${principal.userId}` +
      (principal.degraded ? ' (session unverified: Redis unreachable)' : ''),
  );

  req.principal = principal;
  next();
};
