import type { NextFunction, Request, Response } from 'express';
import { HTTPError } from '@core/exceptions/http.exceptions.js';
import { logger } from '@config/logger.js';

/** Anything a route throws lands here, in the estate's response envelope. */
export const errorHandler = (
  error: Error,
  req: Request,
  res: Response,
  _next: NextFunction,
): void => {
  if (error instanceof HTTPError) {
    res.status(error.status).json({ status: false, message: error.message, data: null });
    return;
  }

  // Unexpected: log it with the correlation id and tell the caller nothing
  // about the internals.
  logger.error(
    `Unhandled error on ${req.method} ${req.originalUrl} (correlation ${req.correlationId}): ${error.stack ?? error.message}`,
  );
  res.status(500).json({ status: false, message: 'Internal error', data: null });
};

/**
 * Express 4 does not forward a rejected promise from an async handler to the
 * error middleware — it hangs the request instead. Every async route is wrapped
 * in this.
 */
export const asyncRoute =
  <T>(handler: (req: Request, res: Response) => Promise<T>) =>
  (req: Request, res: Response, next: NextFunction): void => {
    handler(req, res).catch(next);
  };
