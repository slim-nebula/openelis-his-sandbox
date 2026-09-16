import { randomUUID } from 'node:crypto';
import type { Request, Response } from 'express';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { recordPoll } from '@config/metrics.js';
import { eventPublisher } from '@config/kafka.js';
import {
  asBundle,
  asResource,
  errorOutcome,
  fhirResponse,
  notFoundOutcome,
  searchBundle,
  storedResponse,
  transactionResponseBundle,
} from '@fhir/serialize.js';
import type { BundleEntry, FhirResource, FhirTask } from '@fhir/types.js';
import { tokenOne, tokenSet } from '@fhir/search-params.js';
import { SUPPORTED_TYPES } from '@fhir/types.js';
import type { FhirModel } from '../models/fhir.model.js';
import type { OrderTrackingModel } from '@modules/orders/models/order-tracking.model.js';

/**
 * The bridge's FHIR R4 surface. This is the whole contract with OpenELIS:
 *
 *   GET  /fhir/metadata                    HAPI validates the version here first
 *   GET  /fhir/Task?status=&owner=         the order poll
 *   GET  /fhir/{type}/{id}                 dereferencing Task.for / basedOn / requester
 *   GET  /fhir/{type}?...                  QuestionnaireResponse lookups (empty is fine)
 *   PUT  /fhir/Task/{id}                   OpenELIS writing back accepted / rejected
 *   POST /fhir  |  POST /fhir/{type}       released results pushed back to us
 */
export class FhirController {
  constructor(
    private readonly store: FhirModel,
    private readonly tracking: OrderTrackingModel,
  ) {}

  /** `{scheme}://{host}/fhir`, as the bundle's fullUrls are built from. */
  private baseUrl(req: Request): string {
    return `${req.protocol}://${req.get('host') ?? 'bridge'}/fhir`;
  }

  /**
   * What to echo back after storing a resource.
   *
   * The raw request text when the caller supplied an id, so the response is
   * byte-identical to what arrived — no decimal is reshaped on the way back.
   *
   * When the caller supplied NO id the bridge assigned one, and the response has
   * to carry it or the caller cannot address what it just created. That is the
   * one case worth re-serialising, and it is safe: a client that did not name
   * the resource is not depending on the body coming back unchanged either.
   */
  private echo(rawBody: string, resource: FhirResource, hadId: boolean): string {
    return hadId ? rawBody : JSON.stringify(resource);
  }

  /**
   * _count is honoured but never trusted: a client asking for more than the
   * server is willing to serialise gets the server's answer. `make smoke` asks
   * for 100000 and asserts it is capped.
   */
  private limitFrom(req: Request): number {
    const raw = req.query['_count'];
    const requested = Number(Array.isArray(raw) ? raw[0] : raw);
    if (!Number.isFinite(requested)) return config.maxSearchResults;
    return Math.min(Math.max(Math.trunc(requested), 1), config.maxSearchResults);
  }

  private queryParam(req: Request, name: string): string | null {
    return tokenOne(req.query[name]);
  }

  /**
   * A token parameter that may name several values — `?status=requested,received`
   * or a repeated `?status=`. See fhir/search-params.ts for why dropping one of
   * them loses orders silently.
   */
  private queryParamSet(req: Request, name: string): string[] | null {
    return tokenSet(req.query[name]);
  }

  metadata = (_req: Request, res: Response): void => {
    fhirResponse(res, {
      resourceType: 'CapabilityStatement',
      id: 'bridge-fhir',
      status: 'active',
      date: new Date().toISOString(),
      kind: 'instance',
      software: { name: 'his-openelis-bridge', version: '1.0.0' },
      publisher: 'HIS Sandbox Bridge',
      fhirVersion: '4.0.1',
      format: ['application/fhir+json', 'json'],
      rest: [
        {
          mode: 'server',
          resource: SUPPORTED_TYPES.map((type) => ({
            type,
            interaction: [{ code: 'read' }, { code: 'search-type' }, { code: 'update' }, { code: 'create' }],
          })),
        },
      ],
    });
  };

  search = async (req: Request, res: Response): Promise<void> => {
    const type = req.params.type as string;
    const limit = this.limitFrom(req);

    if (type === 'Task') {
      const status = this.queryParamSet(req, 'status');
      const owner = this.queryParam(req, 'owner');
      const id = this.queryParam(req, '_id');

      // Stamped only for a real order poll, never for a lookup by id.
      if (id === null) recordPoll();

      const tasks = id === null
        ? await this.store.searchAndLeaseTasks(status, owner, limit)
        : await this.store.findTaskById(status, owner, id, limit);

      // A short page is the whole set, so the count query is skipped — this is
      // the common case on a healthy queue and it is the poll's hot path.
      const total = tasks.length < limit ? tasks.length : await this.store.countTasks(status, owner, id);

      if (total > tasks.length) {
        logger.info(
          `Task search truncated to ${tasks.length} of ${total}; the rest follow on later polls`,
        );
      }

      logger.info(
        `Task search status=${status === null ? 'any' : status.join('|')} owner=${owner} ` +
          `-> ${tasks.length} match(es)`,
      );
      fhirResponse(res, searchBundle(tasks, this.baseUrl(req), total));
      return;
    }

    // Everything else: OpenELIS only ever searches QuestionnaireResponse by
    // based-on, and the sandbox never produces any. An empty searchset is the
    // correct answer, not an error.
    if (Object.keys(req.query).length > 0 && type !== 'Patient') {
      fhirResponse(res, searchBundle([], this.baseUrl(req)));
      return;
    }

    fhirResponse(res, searchBundle(await this.store.searchByType(type, limit), this.baseUrl(req)));
  };

  read = async (req: Request, res: Response): Promise<void> => {
    const type = req.params.type as string;
    const id = req.params.id as string;

    // Both reads return TEXT and are written to the response verbatim — no
    // parse, no re-serialise, so a stored 1.10 leaves as 1.10.
    const published = await this.store.getText(type, id);
    if (published !== null) {
      storedResponse(res, published);
      return;
    }

    // Fall back to the inbound mirror so OpenELIS can re-read anything it
    // previously pushed to us.
    const received = await this.store.getReceivedText(type, id);
    if (received !== null) {
      storedResponse(res, received);
      return;
    }

    fhirResponse(res, notFoundOutcome(`${type}/${id}`), 404);
  };

  /**
   * Two very different callers land here:
   *   * OpenELIS accepting or rejecting an order we published
   *   * OpenELIS delivering a changed resource via its rest-hook subscription
   * The task-tracking table tells them apart.
   */
  update = async (req: Request, res: Response): Promise<void> => {
    const type = req.params.type as string;
    const id = req.params.id as string;

    const resource = asResource(req.body);
    if (!resource || req.rawBody === undefined) {
      fhirResponse(res, errorOutcome('Unparseable resource'), 400);
      return;
    }
    const hadId = typeof resource.id === 'string' && resource.id.length > 0;
    resource.id ??= id;

    const tracked = type === 'Task' ? await this.tracking.byTaskId(id) : null;
    if (!tracked) {
      await this.store.storeReceivedRaw(resource.resourceType, resource.id, req.rawBody);
      logger.info(`Received ${type}/${resource.id} from OpenELIS (update)`);
      storedResponse(res, this.echo(req.rawBody, resource, hadId));
      return;
    }

    const task = resource as FhirTask;
    const status = (task.status ?? 'unknown').toLowerCase();

    await this.store.put(resource);
    await this.tracking.setTaskStatus(id, status);

    // The LIS has given its verdict, so the delivery is over. The Task leaves
    // `requested` at the same moment and the poll would stop matching it
    // anyway — this keeps the lease table to live orders rather than to every
    // order ever placed.
    await this.store.releaseDeliveryLease(id);

    // The reason is read off the Task when OpenELIS supplies one, and is
    // otherwise left unstated.
    //
    // This used to say "most often no test matches the LOINC code", which was a
    // guess presented to a clinician as a fact — and the first clean rebuild of
    // this stack proved it a wrong one. That rejection came from a Hibernate
    // Search indexing failure inside OpenELIS (docs/catalogue-discovery-plan.md,
    // defect 0). The laboratory had not declined anything, and the LOINC was
    // fine.
    //
    // A rejection with no reason is worth surfacing AS having no reason. It
    // sends whoever reads it to the laboratory, which is where the answer is;
    // the old wording sent them to the catalogue, which is where it was not.
    const reason = task.statusReason?.text ?? task.statusReason?.coding?.[0]?.display;

    const { hisStatus, detail } = this.verdict(status, reason);

    logger.info(`OpenELIS set Task ${id} to ${status} for order ${tracked.orderNumber}`);

    const topic =
      hisStatus === 'REJECTED_BY_LIS' ? config.kafka.topics.orderFailed : config.kafka.topics.orderSent;
    const correlationId = tracked.correlationId ?? randomUUID();

    await eventPublisher.publish(
      topic,
      tracked.orderNumber,
      {
        eventId: randomUUID(),
        correlationId: tracked.correlationId,
        orderId: tracked.orderId,
        orderNumber: tracked.orderNumber,
        status: hisStatus,
        detail,
      },
      correlationId,
    );

    storedResponse(res, this.echo(req.rawBody, resource, hadId));
  };

  private verdict(status: string, reason: string | undefined): { hisStatus: string; detail: string } {
    switch (status) {
      case 'accepted':
        return { hisStatus: 'ACCEPTED_BY_LIS', detail: 'OpenELIS accepted the electronic order' };
      case 'rejected':
        return {
          hisStatus: 'REJECTED_BY_LIS',
          detail:
            reason === undefined || reason.trim().length === 0
              ? 'OpenELIS rejected the order and gave no reason. Check the order in ' +
                'OpenELIS and its log before assuming a catalogue mismatch.'
              : `OpenELIS rejected the order: ${reason}`,
        };
      case 'received':
        return { hisStatus: 'SENT_TO_LIS', detail: 'OpenELIS received the order' };
      default:
        return { hisStatus: 'SENT_TO_LIS', detail: `OpenELIS set task status to ${status}` };
    }
  }

  create = async (req: Request, res: Response): Promise<void> => {
    const resource = asResource(req.body);
    if (!resource || req.rawBody === undefined) {
      fhirResponse(res, errorOutcome('Unparseable resource'), 400);
      return;
    }

    const hadId = typeof resource.id === 'string' && resource.id.length > 0;
    resource.id ??= randomUUID();
    await this.store.storeReceivedRaw(resource.resourceType, resource.id, req.rawBody);
    logger.info(`Received ${resource.resourceType}/${resource.id} from OpenELIS (create)`);
    storedResponse(res, this.echo(req.rawBody, resource, hadId), 201);
  };

  /**
   * The transaction/batch bundle: how OpenELIS's periodic data export pushes a
   * batch of released results in one call.
   */
  transaction = async (req: Request, res: Response): Promise<void> => {
    const resource = asResource(req.body);
    if (!resource || req.rawBody === undefined) {
      fhirResponse(res, errorOutcome('Unparseable payload'), 400);
      return;
    }

    const bundle = asBundle(resource);
    if (!bundle) {
      const hadId = typeof resource.id === 'string' && resource.id.length > 0;
      resource.id ??= randomUUID();
      await this.store.storeReceivedRaw(resource.resourceType, resource.id, req.rawBody);
      storedResponse(res, this.echo(req.rawBody, resource, hadId));
      return;
    }

    // Ids are decided here, one slot per entry INCLUDING entries with no
    // resource, so the array lines up with the bundle's own positions when
    // Postgres zips them by ordinality. An empty string marks a slot to skip.
    const bundleEntries = bundle.entry ?? [];
    const ids = bundleEntries.map((entry) =>
      entry.resource?.resourceType ? (entry.resource.id ?? randomUUID()) : '',
    );

    if (ids.some((id) => id !== '')) {
      // The raw bundle text goes to Postgres, which splits it — see
      // storeBundleRaw. The parsed copy is used only to decide the ids.
      await this.store.storeBundleRaw(req.rawBody, ids);
    }

    const entries: BundleEntry[] = [];
    bundleEntries.forEach((entry, index) => {
      const item: FhirResource | undefined = entry.resource;
      const id = ids[index];
      if (!item || !id) return;
      entries.push({ response: { status: '200 OK', location: `${item.resourceType}/${id}` } });
    });

    logger.info(`Received bundle from OpenELIS with ${entries.length} resource(s)`);
    fhirResponse(res, transactionResponseBundle(entries));
  };
}
