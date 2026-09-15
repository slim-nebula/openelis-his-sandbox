import { timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';

/**
 * Bearer-token check for the endpoints that change something.
 *
 * One endpoint needs it today: /admin/catalogue/refresh replaces the test menu
 * every doctor orders from, and it is routed through Kong precisely because a
 * technician presses it from a browser — which is also what makes it reachable
 * from the edge.
 *
 * The clinical API is NOT behind this. Patients and orders need per-user
 * identity, not a shared operator token; that is the estate's JWT, and a larger
 * piece of work recorded in docs/security.md.
 */
const presented = (header: string | undefined): boolean => {
  if (!header?.toLowerCase().startsWith('bearer ')) return false;

  const supplied = Buffer.from(header.slice('bearer '.length).trim());
  const expected = Buffer.from(config.adminToken);

  // Length must match before timingSafeEqual, which throws on a mismatch — and
  // comparing lengths first leaks only the length, not the contents.
  if (supplied.length !== expected.length) return false;
  return timingSafeEqual(supplied, expected);
};

export const requireAdminToken = (req: Request, res: Response, next: NextFunction): void => {
  // Fail closed. An unset variable must not be the thing that opens a door —
  // that mistake works in testing and is discovered in production by someone
  // who was not looking for it.
  if (!config.adminToken) {
    logger.error(`Refused ${req.method} ${req.originalUrl}: HIS_ADMIN_TOKEN is not set`);
    res.status(503).json({
      status: false,
      message: 'Administrative access is not configured on this service.',
      data: null,
    });
    return;
  }

  if (!presented(req.headers.authorization)) {
    // The token is never logged, at any level. A rejected credential is often a
    // correct credential for somewhere else.
    logger.warn(`Refused ${req.method} ${req.originalUrl}: bad or missing bearer token`);
    res.status(401).json({
      status: false,
      message: 'A valid bearer token is required for this endpoint.',
      data: null,
    });
    return;
  }

  next();
};
