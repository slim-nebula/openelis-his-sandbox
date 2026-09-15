import type { NextFunction, Request, Response } from 'express';
import { audit, auditRefusal, AuditOutcome, type AuditAction } from './audit.writer.js';

/**
 * Records access to patient data, per route.
 *
 * Applied per route rather than globally on purpose. A global middleware would
 * have to guess what the request touched, and would produce a row for /health
 * and /metrics — noise that makes the trail harder to read, in a table that is
 * kept for years.
 *
 * The patient id comes from the route, and the actor from `req.user`, which is
 * the VERIFIED token. Never from the body: an audit trail that records what the
 * caller claimed is not evidence of anything.
 */
const peerOf = (req: Request): string | undefined => {
  const forwarded = req.headers['x-forwarded-for'];
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded?.split(',')[0];
  // Kong and the edge proxy both sit in front, so the socket address is theirs.
  // Trusted here because nothing reaches this service except through them; a
  // deployment where that is not true must not trust this header.
  return (first ?? req.socket.remoteAddress ?? undefined)?.trim();
};

export const auditAccess =
  (eventType: string, action: AuditAction, entity?: (req: Request) => string | undefined) =>
  (req: Request, _res: Response, next: NextFunction): void => {
    const ref = entity?.(req);

    // Awaited via the promise chain rather than blocking `next()`: the read is
    // already committed to happening, and the write is to the same database the
    // handler is about to use. A failure surfaces through the error handler.
    void audit({
      eventType,
      action,
      actorId: req.user?.usr_id,
      actorName: req.user?.usr_name,
      actorIp: peerOf(req),
      entityRef: ref,
      entityType: ref ? '1' : undefined, // FHIR: 1 = person
      correlationId: req.correlationId,
    })
      .then(() => next())
      .catch(next);
  };

/**
 * Records a refused access.
 *
 * Called from the auth middleware, not mounted as a route. Failed attempts are
 * where an investigation starts — an audit trail holding only successes answers
 * "who read this" but not "who tried".
 */
export const auditAuthFailure = (
  req: Request,
  reason: string,
  actorId?: string,
): void => {
  auditRefusal({
    eventType: 'auth.rejected',
    action: 'E',
    outcome: AuditOutcome.MinorFailure,
    outcomeDesc: reason,
    actorId,
    actorIp: peerOf(req),
    entityRef: `${req.method} ${req.originalUrl.split('?')[0]}`,
    correlationId: req.correlationId,
  });
};
