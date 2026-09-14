import { Router } from 'express';

/**
 * The FHIR R4 surface OpenELIS integrates with.
 *
 * PHASE 2a: only /fhir/metadata is served. It exists so the mutually
 * authenticated listener has something real behind it — a handshake that
 * completes but 404s proves less than one that returns the document OpenELIS
 * actually asks for first. The store, the searches and the delivery lease
 * arrive in 2b.
 */
export const fhirRouter = Router();

// The eleven types the bridge publishes or accepts. Same list, same order, as
// the .NET service: OpenELIS reads this to decide what it may ask for.
const SUPPORTED_TYPES = [
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

/**
 * The CapabilityStatement. OpenELIS fetches this before it will talk to a
 * remote source, so it is the first thing a new deployment exercises — and the
 * first thing to break if the content type is wrong.
 */
fhirRouter.get('/metadata', (_req, res) => {
  res.type('application/fhir+json').json({
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
});

export default fhirRouter;
