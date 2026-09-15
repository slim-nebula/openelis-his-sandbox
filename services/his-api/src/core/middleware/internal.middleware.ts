import { timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';

/**
 * The credential for calls between services, in the header the estate's gateway
 * already uses for them: `x-internal-api-key`.
 *
 * Only the bridge calls /internal/*, and it is not a person — it has no user to
 * be, so a user token would have to be invented for it and then stored
 * somewhere. A service credential is the honest shape for a service.
 *
 * This is not a substitute for the network boundary. /internal/* is not routed
 * by Kong at all, so the key is what stops something *already inside* the
 * sandbox network from reading every patient in the hospital.
 */
const presented = (supplied: string | undefined): boolean => {
  if (!supplied) return false;

  const a = Buffer.from(supplied);
  const b = Buffer.from(config.internalApiKey);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
};

const headerValue = (req: Request): string | undefined => {
  const raw = req.headers['x-internal-api-key'];
  return Array.isArray(raw) ? raw[0] : raw;
};

export const requireInternalKey = (req: Request, res: Response, next: NextFunction): void => {
  if (!config.internalApiKey) {
    logger.error(`Refused ${req.method} ${req.originalUrl}: INTERNAL_API_KEY is not set`);
    res.status(503).json({
      status: false,
      message: 'Internal access is not configured on this service.',
      data: null,
    });
    return;
  }

  if (!presented(headerValue(req))) {
    logger.warn(`Refused ${req.method} ${req.originalUrl}: bad or missing internal API key`);
    res.status(401).json({
      status: false,
      message: 'A valid internal API key is required for this endpoint.',
      data: null,
    });
    return;
  }

  next();
};
