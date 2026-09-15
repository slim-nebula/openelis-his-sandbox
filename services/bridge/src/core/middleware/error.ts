import type { NextFunction, Request, Response } from 'express';
import { logger } from '@config/logger.js';
import { HTTPError } from '@core/exceptions/http.exceptions.js';

/**
 * RFC 7807, the shape ASP.NET's Results.Problem produced.
 *
 * Kept because it is what `/ops` callers already parse, and because a service
 * that answers refusals in two different shapes depending on which half of it
 * you hit is a service nobody can write a client for. The FHIR surface answers
 * in OperationOutcome instead — a different contract for a different caller,
 * stated deliberately rather than by accident.
 */
/**
 * The reason phrases this service actually emits. Written out rather than
 * derived, because a wrong title is worse than a generic one and there is no
 * table in the standard library to derive it from.
 *
 * ASP.NET set `type` to a link into the HTTP semantics RFC; this uses
 * "about:blank", which RFC 7807 §4.2 defines as "no further information beyond
 * the status code". That is the honest value — the bridge publishes no problem
 * registry — and it is a deliberate divergence, recorded in the README. No
 * suite reads `type` or `title`; both assert the status and the `detail` text.
 */
const TITLES: Readonly<Record<number, string>> = {
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  409: 'Conflict',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  503: 'Service Unavailable',
};

export const problemResponse = (res: Response, status: number, detail: string): void => {
  res.status(status).type('application/problem+json').json({
    type: 'about:blank',
    title: TITLES[status] ?? 'Error',
    status,
    detail,
  });
};

/**
 * Last in the chain. Express 5 forwards a rejected promise here on its own, so
 * unlike his-api there is no asyncRoute wrapper to remember — which is the main
 * practical reason this service is on Express 5.
 */
export const errorHandler = (
  error: Error,
  req: Request,
  res: Response,
  _next: NextFunction,
): void => {
  if (res.headersSent) return;

  if (error instanceof HTTPError) {
    problemResponse(res, error.status, error.message);
    return;
  }

  logger.error(
    `Unhandled error on ${req.method} ${req.originalUrl} ` +
      `(correlation ${req.correlationId}): ${error.stack ?? error.message}`,
  );
  problemResponse(res, 500, 'Internal error');
};
