import { randomUUID } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';

declare module 'express-serve-static-core' {
  interface Request {
    correlationId: string;
  }
}

/**
 * Kong stamps X-Correlation-ID at the edge. Anything arriving without one — the
 * bridge calling /internal/*, or curl — gets one here, so every log line, Kafka
 * header and downstream call produced by a request can be tied back to it.
 */
export const correlation = (req: Request, res: Response, next: NextFunction): void => {
  const header = req.headers['x-correlation-id'];
  const id = (Array.isArray(header) ? header[0] : header)?.trim();
  req.correlationId = id && id.length > 0 ? id : randomUUID();
  res.setHeader('X-Correlation-ID', req.correlationId);
  next();
};
