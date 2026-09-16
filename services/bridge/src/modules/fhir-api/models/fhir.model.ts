import { query, queryOne, type Row } from '@config/db.js';
import { logger } from '@config/logger.js';
import { config } from '@config/env.js';
import type { FhirResource } from '@fhir/types.js';

/**
 * The bridge's FHIR store: the resources it publishes for OpenELIS to poll, and
 * a mirror of everything OpenELIS pushes back. Neither the HIS service nor
 * OpenELIS has credentials for this database.
 *
 * Content is stored and returned as jsonb, never through an object model — see
 * the note in src/fhir/types.ts.
 */

/**
 * jsonb comes back from node-postgres already parsed.
 *
 * WHY THE SEARCHES PARSE WHERE THE READS DO NOT
 *
 * getText() and getReceivedText() return raw text because a resource read by id
 * may be a RESULT, and parsing a result through JavaScript numbers loses
 * decimal precision (see getText). The searches below cannot do that — their
 * rows have to be embedded as objects inside a Bundle — but they do not need
 * to: every one of them reads `fhir_resources`, which holds only what this
 * bridge PUBLISHES. Those are orders — Task, ServiceRequest, Patient, Specimen,
 * Practitioner, Organization — and none of them carries a measured value.
 *
 * The rule to keep: anything reading `received_resources`, where results live,
 * must go through the text path.
 */
const contentOf = (row: Row): FhirResource => row.content as FhirResource;

/**
 * The Task statuses that mean "the laboratory still owes us an answer".
 *
 * These are exactly the states OpenELIS's remote poll asks for, and they are
 * the only ones completeTaskIfOutstanding is allowed to move out of — so a
 * verdict the laboratory actually gave can never be overwritten.
 */
const OUTSTANDING_TASK_STATUSES = ['requested', 'received'];

export class FhirModel {
  // --- Published (outbound) resources ---------------------------------------

  /**
   * Insert or update, bumping the version.
   *
   * Note `$4::jsonb` rather than handing pg an object: node-postgres would
   * serialise a JS object to its own JSON, and the point of this column is that
   * what OpenELIS receives is what was written.
   */
  async put(resource: FhirResource): Promise<void> {
    await query(
      `INSERT INTO bridge.fhir_resources (resource_type, resource_id, version_id, content, last_updated)
       VALUES ($1, $2, 1, $3::jsonb, now())
       ON CONFLICT (resource_type, resource_id) DO UPDATE SET
           version_id   = bridge.fhir_resources.version_id + 1,
           content      = excluded.content,
           last_updated = now()`,
      [resource.resourceType, resource.id, JSON.stringify(resource)],
    );
  }

  /**
   * A single resource, as TEXT rather than as a parsed object.
   *
   * WHY `content::text` AND NOT `content`
   *
   * node-postgres parses a jsonb column into JavaScript values, and JavaScript
   * has one number type. Postgres stores JSON numbers as `numeric` and keeps
   * `1.10` as `1.10`; a JSON.parse/stringify round-trip through a JS double
   * returns `1.1`.
   *
   * For a laboratory result that trailing zero is not decoration — it states
   * the precision of the measurement, and dropping it silently reports a
   * different number than the analyser produced. The .NET service did not have
   * this problem because it selected `content::text` and parsed into a type
   * with real decimals.
   *
   * So the text goes to the caller untouched and is written to the response
   * verbatim. Nothing in this service needs to read a published resource's
   * fields on the way out.
   */
  async getText(type: string, id: string): Promise<string | null> {
    const row = await queryOne<Row>(
      `SELECT content::text AS content FROM bridge.fhir_resources
        WHERE resource_type = $1 AND resource_id = $2`,
      [type, id],
    );
    return row ? String(row.content) : null;
  }

  /**
   * A Task lookup by id. A read, never a delivery.
   *
   * This must NOT take a lease: GET /fhir/Task/{id} and ?_id= have to agree, or
   * debugging the queue becomes impossible — looking at an order would hide it
   * from the laboratory. Only the poll, which never carries _id, claims.
   */
  async findTaskById(status: string[] | null, owner: string | null, id: string, limit: number): Promise<FhirResource[]> {
    const rows = await query<Row>(
      `SELECT content FROM bridge.fhir_resources
        WHERE resource_type = 'Task'
          AND ($1::text[] IS NULL OR content ->> 'status' = ANY($1::text[]))
          AND ($2::text IS NULL OR content -> 'owner' ->> 'reference' = $2::text)
          AND resource_id = $3
        ORDER BY last_updated
        LIMIT $4`,
      [status, owner, id, limit],
    );
    return rows.map(contentOf);
  }

  /**
   * THE ORDER POLL: returns Tasks and claims them in one statement.
   *
   * The claim has to be atomic with the read, because the failure it exists to
   * prevent IS two polls landing together (db/bridge/005_delivery_lease.sql).
   * Two things make it so:
   *
   *   * the LEFT JOIN drops Tasks under a live lease, which handles the
   *     ordinary case and keeps LIMIT counting only claimable rows;
   *   * `ON CONFLICT ... DO UPDATE ... WHERE leased_until <= now()` handles the
   *     simultaneous case. It takes a row lock, so of two transactions racing
   *     for the same Task the second finds the lease already moved into the
   *     future, its WHERE fails, and it RETURNS nothing. Only the winner is
   *     handed the Task.
   *
   * A Task is therefore delivered to exactly one poll at a time, without its
   * status being touched.
   *
   * Capped, and oldest first. Uncapped, one poll serialises every Task the
   * bridge has ever published, so the cost of asking "anything new?" grows with
   * the age of the deployment and is worst exactly when the laboratory is
   * busiest. The cap needs no paging to be correct here, because of what the
   * query is: OpenELIS searches status=requested, and accepting an order moves
   * it out of that set, so a capped page drains itself over successive polls.
   * Oldest first is what makes that a queue rather than a lottery — without the
   * ordering, an order arriving during a backlog could be starved indefinitely
   * while newer ones are served.
   *
   * The SQL is the .NET statement unchanged except for the parameter style.
   * `make_interval(secs => ...)` is cast explicitly because pg cannot infer a
   * parameter's type inside a named argument.
   */
  async searchAndLeaseTasks(status: string[] | null, owner: string | null, limit: number): Promise<FhirResource[]> {
    const rows = await query<Row>(
      `WITH candidates AS (
           SELECT r.resource_id
             FROM bridge.fhir_resources r
             LEFT JOIN bridge.delivery_leases l ON l.resource_id = r.resource_id
            WHERE r.resource_type = 'Task'
              AND ($1::text[] IS NULL OR r.content ->> 'status' = ANY($1::text[]))
              AND ($2::text IS NULL OR r.content -> 'owner' ->> 'reference' = $2::text)
              AND (l.leased_until IS NULL OR l.leased_until <= now())
            ORDER BY r.last_updated
            LIMIT $3
       ),
       claimed AS (
           INSERT INTO bridge.delivery_leases AS l (resource_id, leased_until)
           SELECT resource_id, now() + make_interval(secs => $4::double precision) FROM candidates
           ON CONFLICT (resource_id) DO UPDATE
              SET leased_until = excluded.leased_until,
                  deliveries   = l.deliveries + 1,
                  last_at      = now()
            WHERE l.leased_until <= now()
           RETURNING resource_id, deliveries
       )
       SELECT r.content, c.deliveries::int AS deliveries
         FROM bridge.fhir_resources r
         JOIN claimed c ON c.resource_id = r.resource_id
        ORDER BY r.last_updated`,
      [status, owner, limit, config.taskLeaseSeconds],
    );

    // Above one means the LIS was given this order and never came back with a
    // verdict. Nothing else counts that — OpenELIS keeps no attempt counter for
    // a failing import — so this is the only place a repeatedly failing order
    // announces itself.
    for (const row of rows) {
      const deliveries = Number(row.deliveries);
      if (deliveries > 1) {
        logger.warn(
          `Task handed to the LIS for the ${deliveries} time — the previous delivery was never ` +
            `acknowledged. Repeated growth here means the LIS cannot import it: ${contentOf(row).id ?? 'unknown'}`,
        );
      }
    }

    return rows.map(contentOf);
  }

  /**
   * Total matching the same predicate, so a bundle can report a truthful total
   * when it has been truncated.
   *
   * `count(*)` is bigint, which node-postgres hands back as a STRING to avoid
   * silent precision loss. Cast in SQL and coerce at the call site — a string
   * here would serialise into the bundle's `total` as `"7"` rather than 7.
   */
  async countTasks(status: string[] | null, owner: string | null, id: string | null): Promise<number> {
    const row = await queryOne<Row>(
      `SELECT count(*)::int AS total FROM bridge.fhir_resources
        WHERE resource_type = 'Task'
          AND ($1::text[] IS NULL OR content ->> 'status' = ANY($1::text[]))
          AND ($2::text IS NULL OR content -> 'owner' ->> 'reference' = $2::text)
          AND ($3::text IS NULL OR resource_id = $3::text)`,
      [status, owner, id],
    );
    return Number(row?.total ?? 0);
  }

  async searchByType(type: string, limit: number): Promise<FhirResource[]> {
    const rows = await query<Row>(
      `SELECT content FROM bridge.fhir_resources
        WHERE resource_type = $1 ORDER BY last_updated LIMIT $2`,
      [type, limit],
    );
    return rows.map(contentOf);
  }

  /**
   * Ends the lease once the laboratory has given a verdict, WITHOUT erasing the
   * delivery history.
   *
   * This is an UPDATE and must stay one. It used to DELETE the row, which
   * quietly defeated the point of the table: `deliveries` is the attempt
   * counter OpenELIS does not have — the only record of how many times an order
   * had to be handed over before it stuck — and deleting on success threw that
   * away for every order that worked, leaving the counter meaningful only for
   * failures. A Task re-delivered later then started counting from one again,
   * so the number under-reported precisely when someone was investigating.
   *
   * Expiring releases the Task just as effectively — the claim query tests
   * `leased_until <= now()` — and keeps first_at, last_at and the count.
   * The retention sweep prunes this table — settled Tasks only, so a live
   * attempt counter is never forgotten. Releasing is not the place to prune.
   */
  async releaseDeliveryLease(resourceId: string): Promise<void> {
    await query(
      `UPDATE bridge.delivery_leases
          SET leased_until = now() - interval '1 second'
        WHERE resource_id = $1`,
      [resourceId],
    );
  }

  /**
   * Closes a Task whose result has already come back, and reports whether it
   * had to.
   *
   * THE LOOP THIS ENDS. A Task leaves `requested` only when OpenELIS
   * acknowledges it by PUTting it back. If that acknowledgement is lost — the
   * import half-completes, a storage error aborts the pass, the container is
   * restarted mid-write — nothing else ever moves it. The poll finds it again
   * every cycle, for ever, and keeps handing the laboratory an order it has
   * already done. One such Task in this sandbox was delivered over a hundred
   * times while its result sat finalised in the HIS.
   *
   * Note this is NOT the undelivered-order alert, which already excludes orders
   * a result has been forwarded for. That silenced the alarm and left the
   * laboratory receiving the same finished order every thirty seconds; this is
   * the half that costs the laboratory something.
   *
   * A released result is proof the laboratory did the work, so it is also proof
   * the Task is finished, whatever the acknowledgement did. `completed` is the
   * honest terminal status: `accepted` would assert an acknowledgement that
   * never arrived.
   *
   * GUARDED, and the guard is the safety. The status predicate means this can
   * only ever move a Task OUT of an outstanding state — it can never reopen a
   * rejection, overwrite a verdict the laboratory actually gave, or fire twice
   * for the corrections that follow a result.
   *
   * jsonb_set rather than read-modify-write: every other field is preserved
   * byte for byte, which matters because `content` is otherwise only ever
   * handed out as text to protect numeric precision (see getText).
   */
  async completeTaskIfOutstanding(resourceId: string): Promise<boolean> {
    const rows = await query(
      `UPDATE bridge.fhir_resources
          SET content      = jsonb_set(content, '{status}', to_jsonb('completed'::text)),
              version_id   = version_id + 1,
              last_updated = now()
        WHERE resource_type = 'Task'
          AND resource_id   = $1
          AND content ->> 'status' = ANY($2::text[])
        RETURNING resource_id`,
      [resourceId, OUTSTANDING_TASK_STATUSES],
    );
    return rows.length > 0;
  }

  // --- Inbound mirror -------------------------------------------------------

  /**
   * Everything OpenELIS pushes, kept as it arrived.
   *
   * Takes the request's RAW body text, not a re-serialised object, for the
   * precision reason documented on getText(): this is the path results arrive
   * on, so it is the one where a lost trailing zero would change a reported
   * value. The id is applied with jsonb_set inside Postgres so that assigning a
   * missing id does not mean rebuilding the document in JavaScript.
   *
   * `processed = false` on every write, including an update of a row already
   * processed: a resource OpenELIS sends again has changed, and a corrected
   * result arriving under an id already marked done must be looked at again
   * rather than skipped.
   */
  async storeReceivedRaw(resourceType: string, id: string, rawJson: string): Promise<void> {
    await query(
      // $2 is cast to text in BOTH places it appears. Left uncast in the column
      // position, Postgres deduces varchar there and text inside to_jsonb, then
      // refuses the statement with "inconsistent types deduced for parameter".
      `INSERT INTO bridge.received_resources (resource_type, resource_id, content, processed)
       VALUES ($1, $2::text, jsonb_set($3::jsonb, '{id}', to_jsonb($2::text), true), false)
       ON CONFLICT (resource_type, resource_id) DO UPDATE SET
           content     = excluded.content,
           received_at = now(),
           processed   = false`,
      [resourceType, id, rawJson],
    );
  }

  /**
   * Every resource in a pushed transaction bundle, in one statement.
   *
   * Splitting the bundle in SQL rather than in JavaScript is the same precision
   * argument once more: the entries never become JS values, so a result of
   * `1.10` is stored as `1.10`. The ids are decided by the caller and zipped by
   * position with WITH ORDINALITY, so id assignment stays in TypeScript where
   * it can be reasoned about.
   *
   * DISTINCT ON keeps the LAST entry for a repeated (type, id). Postgres
   * refuses an ON CONFLICT that would touch one row twice in a single
   * statement, and the .NET version — which looped — let a later entry
   * overwrite an earlier one. This reproduces that.
   */
  async storeBundleRaw(rawBundleJson: string, ids: string[]): Promise<void> {
    await query(
      `WITH entries AS (
           SELECT e.value -> 'resource' AS resource, e.ordinality AS ord
             FROM jsonb_array_elements($1::jsonb -> 'entry')
                  WITH ORDINALITY AS e(value, ordinality)
       ),
       identified AS (
           SELECT resource, ord, ($2::text[])[ord] AS assigned_id
             FROM entries
            WHERE resource IS NOT NULL
              AND resource ->> 'resourceType' IS NOT NULL
              AND ($2::text[])[ord] <> ''
       ),
       deduplicated AS (
           SELECT DISTINCT ON (resource ->> 'resourceType', assigned_id)
                  resource ->> 'resourceType' AS resource_type,
                  assigned_id                 AS resource_id,
                  jsonb_set(resource, '{id}', to_jsonb(assigned_id), true) AS content
             FROM identified
            ORDER BY resource ->> 'resourceType', assigned_id, ord DESC
       )
       INSERT INTO bridge.received_resources (resource_type, resource_id, content, processed)
       SELECT resource_type, resource_id, content, false FROM deduplicated
       ON CONFLICT (resource_type, resource_id) DO UPDATE SET
           content     = excluded.content,
           received_at = now(),
           processed   = false`,
      [rawBundleJson, ids],
    );
  }

  async getReceivedText(type: string, id: string): Promise<string | null> {
    const row = await queryOne<Row>(
      `SELECT content::text AS content FROM bridge.received_resources
        WHERE resource_type = $1 AND resource_id = $2`,
      [type, id],
    );
    return row ? String(row.content) : null;
  }
}
