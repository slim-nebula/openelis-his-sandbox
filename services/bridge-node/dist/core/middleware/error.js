import { logger } from '../../config/logger.js';
import { HTTPError } from '../exceptions/http.exceptions.js';
/**
 * RFC 7807, the shape ASP.NET's Results.Problem produced.
 *
 * Kept because it is what `/ops` callers already parse, and because a service
 * that answers refusals in two different shapes depending on which half of it
 * you hit is a service nobody can write a client for. The FHIR surface answers
 * in OperationOutcome instead — a different contract for a different caller,
 * stated deliberately rather than by accident.
 */
export const problemResponse = (res, status, detail) => {
    res.status(status).type('application/problem+json').json({
        type: 'about:blank',
        title: status === 401 ? 'Unauthorized' : status === 403 ? 'Forbidden' : 'Error',
        status,
        detail,
    });
};
/**
 * Last in the chain. Express 5 forwards a rejected promise here on its own, so
 * unlike his-api there is no asyncRoute wrapper to remember — which is the main
 * practical reason this service is on Express 5.
 */
export const errorHandler = (error, req, res, _next) => {
    if (res.headersSent)
        return;
    if (error instanceof HTTPError) {
        problemResponse(res, error.status, error.message);
        return;
    }
    logger.error(`Unhandled error on ${req.method} ${req.originalUrl} ` +
        `(correlation ${req.correlationId}): ${error.stack ?? error.message}`);
    problemResponse(res, 500, 'Internal error');
};
