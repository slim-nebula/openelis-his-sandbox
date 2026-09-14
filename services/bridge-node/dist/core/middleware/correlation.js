import { randomUUID } from 'node:crypto';
/**
 * One id per request, minted at the edge and echoed back.
 *
 * The bridge is the middle of a chain that crosses two databases, a broker and
 * an organisational boundary, so this is what makes "what happened to order
 * LAB-…" answerable at all. It rides onto every Kafka header the bridge
 * publishes and every call it makes to his-api.
 */
export const correlation = (req, res, next) => {
    const header = req.headers['x-correlation-id'];
    const supplied = Array.isArray(header) ? header[0] : header;
    req.correlationId = supplied?.trim() || randomUUID();
    res.setHeader('X-Correlation-ID', req.correlationId);
    next();
};
