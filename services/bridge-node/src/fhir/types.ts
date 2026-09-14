/**
 * The FHIR R4 subset this service actually needs.
 *
 * WHY THERE IS NO FHIR LIBRARY HERE
 *
 * The bridge is a courier, not a validator. It stores resources as jsonb and
 * hands them back, and across the whole surface it reads exactly five fields:
 * `resourceType`, `id`, `Task.status`, `Task.owner.reference` and
 * `Task.statusReason`. Everything else travels through untouched.
 *
 * A library would bring a model for all 145 R4 resource types, a serialiser
 * whose output this service does not control, and a parse step between the
 * database and the wire. The .NET version had exactly that, and it round-tripped
 * every resource through an object model on the way out — which is a chance to
 * change bytes that OpenELIS has already accepted. Here the stored jsonb IS the
 * response body.
 *
 * It also matters for who this is written for: a reader can see that FHIR is
 * JSON with a `resourceType` on it, rather than seeing a library call and having
 * to take that on faith.
 *
 * The types below are therefore about being HONEST about what is known, not
 * about modelling the specification. Anything unread is `unknown`.
 */

/** Any resource. The index signature is the point: unread fields survive. */
export interface FhirResource {
  resourceType: string;
  id?: string;
  [field: string]: unknown;
}

/** A resource as it comes out of the store, with the store's own metadata. */
export interface StoredResource {
  resourceType: string;
  resourceId: string;
  versionId: number;
  content: FhirResource;
  lastUpdated: string | null;
}

export interface Reference {
  reference?: string;
  display?: string;
}

export interface CodeableConcept {
  coding?: { system?: string; code?: string; display?: string }[];
  text?: string;
}

/**
 * Only the parts of Task the bridge reads. A Task carries far more than this —
 * and all of it survives, because FhirResource's index signature keeps it.
 */
export interface FhirTask extends FhirResource {
  resourceType: 'Task';
  status?: string;
  owner?: Reference;
  statusReason?: CodeableConcept;
}

export interface BundleEntry {
  fullUrl?: string;
  resource?: FhirResource;
  search?: { mode: 'match' | 'include' | 'outcome' };
  response?: { status: string; location?: string };
}

export interface Bundle extends FhirResource {
  resourceType: 'Bundle';
  type: string;
  total?: number;
  entry?: BundleEntry[];
  meta?: { lastUpdated?: string };
}

export interface OperationOutcome extends FhirResource {
  resourceType: 'OperationOutcome';
  issue: {
    severity: 'fatal' | 'error' | 'warning' | 'information';
    code: string;
    diagnostics?: string;
  }[];
}

/**
 * What the bridge will accept a push of, and what /fhir/metadata declares.
 *
 * This list must stay a SUPERSET of org.openelisglobal.fhir.subscriber.resources
 * in common.properties. OpenELIS registers one Subscription per name there and
 * pushes unconditionally; a type missing here is refused at the door, which
 * shows up as a permanently failing export on the laboratory's side and as
 * nothing at all on ours. Adding a name to that property without adding it here
 * is strictly worse than not subscribing.
 *
 * Organization is present for referral (send-out) testing: it names the
 * laboratory a specimen was sent to. Nothing reads it yet, but it must be
 * accepted BEFORE the first send-out — resources are pushed when they change,
 * and a reference laboratory configured earlier is not re-pushed just because we
 * started listening.
 */
export const SUPPORTED_TYPES = [
  'Task',
  'ServiceRequest',
  'Patient',
  'Specimen',
  'Practitioner',
  'Observation',
  'DiagnosticReport',
  'QuestionnaireResponse',
  'Location',
  'Encounter',
  'Organization',
] as const;
