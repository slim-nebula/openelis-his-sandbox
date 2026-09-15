import type { PoolClient } from 'pg';
import { pool } from '@config/db.js';
import { logger } from '@config/logger.js';
import { config } from '@config/env.js';

/**
 * The security audit trail: who accessed which patient's data, when, from
 * where, and whether it succeeded.
 *
 * NOT the application log, and not `lab_order_events`. Those answer "what did
 * the software do" and "what happened to this order". Neither can answer "which
 * clinician opened this patient's record last Tuesday", which is the question an
 * audit trail is kept to answer — and reads leave no other trace at all.
 *
 * Shaped as FHIR AuditEvent (R4), the current spelling of RFC 3881 / DICOM
 * Supplement 95, which is what IHE ATNA asks for.
 */
export type AuditAction = 'C' | 'R' | 'U' | 'D' | 'E';

/** FHIR AuditEvent.outcome. */
export const AuditOutcome = {
  Success: '0',
  MinorFailure: '4',
  SeriousFailure: '8',
} as const;

// `| undefined` is spelled out on every optional field because tsconfig sets
// exactOptionalPropertyTypes: an absent property and a property set to
// undefined are then different types, and every caller here builds this object
// from expressions like `req.user?.usr_id`, which produce the second.
export interface AuditEvent {
  eventType: string;
  action: AuditAction;
  outcome?: (typeof AuditOutcome)[keyof typeof AuditOutcome] | undefined;
  outcomeDesc?: string | undefined;
  actorId?: string | undefined;
  actorName?: string | undefined;
  actorIp?: string | undefined;
  /** A FHIR reference — `Patient/<id>`. The reference only, never the data. */
  entityRef?: string | undefined;
  entityType?: string | undefined;
  correlationId?: string | undefined;
}

const INSERT = `
  INSERT INTO his.audit_events
    (event_type, action, outcome, outcome_desc, actor_id, actor_name, actor_ip,
     source, entity_ref, entity_type, correlation_id)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`;

const values = (event: AuditEvent): unknown[] => [
  event.eventType,
  event.action,
  event.outcome ?? AuditOutcome.Success,
  event.outcomeDesc ?? null,
  event.actorId ?? null,
  event.actorName ?? null,
  // inet rejects an empty string, and an unknown peer is honestly null.
  event.actorIp || null,
  config.serviceName,
  event.entityRef ?? null,
  event.entityType ?? null,
  event.correlationId ?? null,
];

/**
 * Records an access that happened as part of a write, inside that write's
 * transaction.
 *
 * This is the important one, and the reason the table lives in this database.
 * An audit trail must not be droppable — an access that was not recorded must
 * not have happened — and taken naively that trades availability for
 * compliance. It does not, if the row is written where the request is already
 * writing: anything that stops the audit write already stops the order. There
 * is no new failure mode, and nothing to decide.
 *
 * Same argument the outbox makes, for a second purpose.
 */
export const auditInTransaction = (
  client: PoolClient,
  event: AuditEvent,
): Promise<unknown> => client.query(INSERT, values(event));

/**
 * Records an access that was not part of a write — a read, a search, a refused
 * request.
 *
 * Awaited, not fired and forgotten. A read that cannot reach the database
 * cannot be served either, so failing here costs no availability that the
 * request had.
 *
 * The one case that must not fail closed is a refusal: if the database is
 * unreachable we still want the 401 to reach the caller rather than becoming a
 * 500. So the caller decides, by choosing which of these two to call.
 */
export const audit = async (event: AuditEvent): Promise<void> => {
  await pool.query(INSERT, values(event));
};

/**
 * Best-effort variant, for recording refusals.
 *
 * A failed access attempt is worth recording and is never worth turning into a
 * different error for the caller — they were being refused anyway. A failure
 * here is logged loudly, because an audit trail silently not being written is
 * how one is discovered to be empty months later.
 */
export const auditRefusal = (event: AuditEvent): void => {
  void pool.query(INSERT, values(event)).catch((error: Error) => {
    logger.error(
      `AUDIT WRITE FAILED for ${event.eventType} (${event.outcomeDesc ?? 'refused'}): ${error.message}`,
    );
  });
};
