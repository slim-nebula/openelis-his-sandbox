import { randomUUID } from 'node:crypto';
import type { Response } from 'express';
import type { Bundle, BundleEntry, FhirResource, OperationOutcome } from './types.js';

export const FHIR_JSON = 'application/fhir+json';

/**
 * Every FHIR response goes out through here, so the content type cannot be
 * forgotten on one route. OpenELIS's client checks it: a body served as
 * application/json is logged on its side as an unparseable response, which
 * looks like a bridge fault and is not one.
 */
export const fhirResponse = (res: Response, body: unknown, status = 200): void => {
  res.status(status).type(FHIR_JSON).send(JSON.stringify(body));
};

/**
 * A resource read from the database, sent back as the exact text Postgres
 * holds.
 *
 * Deliberately NOT parsed and re-serialised. What is stored is what OpenELIS
 * already accepted; a round trip through JavaScript values is an opportunity to
 * change it — and for decimals it takes one, since JS cannot tell 1.10 from
 * 1.1. Passing the text through is both faster and more faithful.
 */
export const storedResponse = (res: Response, json: string, status = 200): void => {
  res.status(status).type(FHIR_JSON).send(json);
};

export const notFoundOutcome = (what: string): OperationOutcome => ({
  resourceType: 'OperationOutcome',
  issue: [{ severity: 'error', code: 'not-found', diagnostics: `${what} not found` }],
});

export const errorOutcome = (message: string): OperationOutcome => ({
  resourceType: 'OperationOutcome',
  issue: [{ severity: 'error', code: 'invalid', diagnostics: message }],
});

/**
 * A searchset bundle.
 *
 * `total` is the number of MATCHES, which is not the same as the number of
 * entries once a page is capped. Reporting the page size as the total would
 * tell a truncated caller it had seen everything — and the caller here is the
 * laboratory deciding whether it has collected all its work.
 */
export const searchBundle = (resources: FhirResource[], baseUrl: string, total?: number): Bundle => ({
  resourceType: 'Bundle',
  id: randomUUID(),
  type: 'searchset',
  total: total ?? resources.length,
  meta: { lastUpdated: new Date().toISOString() },
  entry: resources.map(
    (resource): BundleEntry => ({
      fullUrl: `${baseUrl}/${resource.resourceType}/${resource.id ?? ''}`,
      resource,
      search: { mode: 'match' },
    }),
  ),
});

export const transactionResponseBundle = (entries: BundleEntry[]): Bundle => ({
  resourceType: 'Bundle',
  type: 'transaction-response',
  entry: entries,
});

/**
 * Whether a parsed body is usable as a FHIR resource.
 *
 * express.json() has already rejected malformed JSON, so what is left to check
 * is that the payload is an object carrying a resourceType. A JSON array or a
 * bare string parses successfully and is not a resource.
 */
export const asResource = (body: unknown): FhirResource | null => {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return null;
  const candidate = body as Record<string, unknown>;
  if (typeof candidate.resourceType !== 'string' || candidate.resourceType.length === 0) return null;
  return candidate as FhirResource;
};

export const asBundle = (resource: FhirResource): Bundle | null =>
  resource.resourceType === 'Bundle' ? (resource as Bundle) : null;
