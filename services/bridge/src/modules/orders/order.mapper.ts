import { locationIdFor, practitionerIdFor, specimenIdFor, taskIdFor } from '@fhir/identity.js';
import type { FhirResource } from '@fhir/types.js';
import type { IHisOrder, IMappedOrder } from './types/order.types.js';

/**
 * Turns a HIS lab order into the FHIR R4 resources OpenELIS expects to find
 * when it polls. The shape is dictated by OpenELIS's importer:
 *
 *   Task.status   = requested       (the poll filters on this)
 *   Task.owner    = the configured lab identity, as an ORGANIZATION (the poll
 *                   filters on this too; the type is load-bearing — see below)
 *   Task.for      -> Patient
 *   Task.basedOn  -> ServiceRequest
 *   ServiceRequest.code carries a http://loinc.org coding, which is the ONLY
 *                   thing OpenELIS matches a test on
 *   ServiceRequest.identifier[0].value becomes the LIS-side external order id
 *   ServiceRequest.requester -> Practitioner, the ordering clinician
 *
 * Every resource id is a UUID because OpenELIS calls UUID.fromString() on the
 * Practitioner (and stores the others as uuid columns).
 *
 * These are plain objects rather than library types, and the field ORDER below
 * is the order the .NET serialiser emitted, so a diff between the two
 * implementations' output stays readable.
 */

export const OE_SYSTEM = 'http://openelis-global.org';
export const LOINC_SYSTEM = 'http://loinc.org';
export const ORDER_NUMBER_SYSTEM = 'http://his-sandbox.local/lab-order';

const priorityOf = (priority: string | null): string => {
  switch (priority?.toLowerCase()) {
    case 'stat':
    case 'urgent':
      return 'stat';
    case 'asap':
      return 'asap';
    default:
      return 'routine';
  }
};

const genderOf = (sex: string): string => {
  switch (sex) {
    case 'M':
      return 'male';
    case 'F':
      return 'female';
    default:
      return 'unknown';
  }
};

/**
 * Splits a display name into given and family for a system that reads them
 * separately (getGivenAsSingleString / getFamily).
 *
 * Last whitespace-separated token is the family name, the rest is given. Crude,
 * and deliberately so: the HIS stores one display string, and any cleverer rule
 * would be a guess about naming conventions this sandbox has no business
 * making. A single-token name becomes the family name alone, because that is
 * the field OpenELIS requires and shows.
 *
 * NOT sanitised. OpenELIS validates provider names against the site's
 * configured lastNameCharset — by default letters, space, apostrophe, dot and
 * hyphen, with NO DIGITS — and rejects anything else when the accessioner
 * saves. Stripping characters here to slip past that would alter a clinician's
 * identity in a clinical record to avoid an error message; the laboratory
 * refusing a malformed name is the correct outcome, and the fix belongs in the
 * HIS that holds it.
 */
export const splitName = (displayName: string): { given: string | null; family: string } => {
  const parts = displayName
    .split(' ')
    .map((part) => part.trim())
    .filter((part) => part.length > 0);

  if (parts.length === 0) return { given: null, family: displayName.trim() };
  if (parts.length === 1) return { given: null, family: parts[0] as string };
  return { given: parts.slice(0, -1).join(' '), family: parts[parts.length - 1] as string };
};

/**
 * The doctor who placed the order, as a Practitioner OpenELIS can resolve.
 *
 * KEYED ON THE CLINICAL IDENTITY, NOT THE ACCOUNT.
 * lab_orders.ordering_provider_hcp_id is mlh_his_hcp_health_care_provider.id in
 * the HIS this sandbox is built against — the clinician a laboratory holds
 * accountable for a test. The account that signed in (ordering_provider_id /
 * usr_id) stays in the HIS audit trail and is not what travels, for three
 * reasons visible in that schema: usr_id is nullable, so a consultant with no
 * login has no identity to send; it carries no unique constraint, so it can
 * collide; and the clinical record already names doctors by hcp.id, so sending
 * the account would leave the laboratory unable to line up with the HIS.
 *
 * Not the name either, ever. A name-derived identity makes "Dr Konate",
 * "Dr Konaté" and "dr konate" three different clinicians in the laboratory's
 * own provider records — the defect db/his/008 closed inside the HIS, which
 * deriving the FHIR id from the name here would reopen one layer further out.
 *
 * The id MUST be a uuid. LabOrderSearchProvider.addRequester calls
 * UUID.fromString() on it unguarded, so a raw id like "9042" throws
 * IllegalArgumentException inside the accessioning wizard — a 500 on the
 * laboratory's screen, not a missing field.
 *
 * Returns null when there is no clinical identity, which is a real state and
 * not a gap: a receptionist has an account and no provider row. An order with
 * no identified clinician must not acquire one in transit — least of all the
 * account, which would put a login on a laboratory report as though it were a
 * person.
 */
/**
 * The referring site — which clinic or ward sent the sample, where the report
 * goes back, and who the laboratory telephones about a problem.
 *
 * Published as a Location and referenced from Task.location. OpenELIS reads it
 * during import and, if no organization already carries that uuid, CREATES one:
 * named from Location.name, marked active, and linked to the "referring clinic"
 * organization type. The accessioning screen then resolves the same uuid back
 * and pre-fills the Referring Site the technician types today.
 *
 * Verified end to end against stock 3.2.2.0 on 15 September 2026 — see
 * scripts/probe-referring-site.sh, which re-runs it.
 *
 * NO NAME MEANS NO LOCATION. OpenELIS guards only the name assignment, so a
 * nameless Location still creates the organization — just an unnamed one, which
 * the accessioner sees as a blank field indistinguishable from a bug. Sending
 * nothing leaves them typing it, which is today's behaviour and is honest.
 *
 * The site's own code is deliberately NOT the identifier here: it goes on
 * Location.identifier, where it is readable, while identity rests on the
 * derived uuid. See locationIdFor.
 */
const buildReferringSite = (order: IHisOrder): FhirResource | null => {
  const siteKey = order.facilityCode?.trim();
  const name = order.facilityName?.trim();
  if (!siteKey || !name) return null;

  return {
    resourceType: 'Location',
    id: locationIdFor(siteKey),
    status: 'active',
    name,
    identifier: [{ system: `${OE_SYSTEM}/referringSite`, value: siteKey }],
  };
};

const buildOrderingClinician = (order: IHisOrder): FhirResource | null => {
  const hcpId = order.orderingProviderHcpId?.trim();
  const display = order.orderingProvider?.trim();
  if (!hcpId || !display) return null;

  const { given, family } = splitName(display);
  const name: Record<string, unknown> = { family };
  if (given !== null) name.given = [given];

  // The stable key first, so the laboratory can reconcile against the HIS by
  // something better than a spelling.
  const identifier: Record<string, unknown>[] = [{ system: `${OE_SYSTEM}/hcp_id`, value: hcpId }];

  // The licence second, and it is the one a HUMAN in the laboratory will use.
  // hcp_id means nothing outside the HIS; a licence number is what a technician
  // reconciling provider records recognises, and what a regulator asks for.
  if (order.orderingProviderLicense?.trim()) {
    identifier.push({ system: `${OE_SYSTEM}/provider_license`, value: order.orderingProviderLicense.trim() });
  }

  return {
    resourceType: 'Practitioner',
    id: practitionerIdFor(hcpId),
    active: true,
    identifier,
    name: [name],
  };
};

/**
 * Specimen.type.coding, most specific first.
 *
 * The OpenELIS coding carries the sample type's LOCAL ABBREVIATION and is the
 * only one OpenELIS reads (LabOrderSearchProvider walks the codings for system
 * "<OE_SYSTEM>/sampleType" and resolves its code against
 * type_of_sample.local_abbrev). SNOMED is for every other reader; it is
 * interoperable where the abbreviation is meaningless outside this
 * installation, so neither substitutes for the other.
 *
 * With no abbreviation we emit no OpenELIS coding at all rather than guess. A
 * wrong code binds the wrong test confidently; an absent one leaves the
 * decision with the laboratory.
 */
const buildSpecimenCodings = (
  order: IHisOrder,
  specimenAbbreviation: string | null,
): Record<string, unknown>[] => {
  const codings: Record<string, unknown>[] = [];

  if (specimenAbbreviation?.trim()) {
    codings.push({
      system: `${OE_SYSTEM}/sampleType`,
      code: specimenAbbreviation,
      display: order.specimenType,
    });
  }

  if (order.specimenSnomed?.trim()) {
    codings.push({
      system: 'http://snomed.info/sct',
      code: order.specimenSnomed,
      display: order.specimenType,
    });
  }

  return codings;
};

/**
 * @param specimenAbbreviation The sample type's local abbreviation in OpenELIS,
 * resolved from the catalogue, or null when the bridge has never discovered
 * this test. Null is NOT the same as wrong — the CALLER refuses outright when
 * the test IS on the menu but the abbreviation is missing, because that would
 * bind the wrong test silently. An undiscovered test reaches here with null and
 * is sent without the coding, so the LABORATORY decides whether it accepts it.
 */
export const mapOrder = (
  order: IHisOrder,
  labOwnerReference: string,
  labOwnerName: string,
  specimenAbbreviation: string | null,
): IMappedOrder => {
  const patientId = order.patient.patientId;

  // The ServiceRequest id must be the ORDER NUMBER, not the order UUID.
  // OpenELIS's Incoming Orders view reads
  //     ServiceRequest/{electronic_order.external_id}
  // straight out of its local FHIR store (RestElectronicOrdersController), and
  // external_id is whatever we put in ServiceRequest.identifier[0]. With a UUID
  // id that read 404s, and the lab user sees "error in data collection - FHIR
  // resource not found" with no test name on every order we send. Order import
  // still worked, because that path follows Task.basedOn references instead —
  // which is exactly why this stayed invisible from the integration's side.
  //
  // Order numbers are unique, <= 60 chars, and match the FHIR id grammar
  // [A-Za-z0-9-.]{1,64}.
  const serviceRequestId = order.orderNumber;
  const specimenId = specimenIdFor(order.orderId);
  const taskId = taskIdFor(order.orderId);
  const labOwnerId = labOwnerReference.split('/').pop() as string;

  const patientIdentifiers: Record<string, unknown>[] = [
    { system: `${OE_SYSTEM}/pat_guid`, value: patientId },
  ];
  if (order.patient.nationalId?.trim()) {
    patientIdentifiers.push({ system: `${OE_SYSTEM}/pat_nationalId`, value: order.patient.nationalId });
  }

  const patient: FhirResource = {
    resourceType: 'Patient',
    id: patientId,
    active: true,
    identifier: patientIdentifiers,
    name: [{ family: order.patient.lastName, given: [order.patient.firstName] }],
    gender: genderOf(order.patient.sex),
    birthDate: order.patient.dateOfBirth,
  };

  if (order.patient.phone?.trim()) {
    patient.telecom = [{ system: 'phone', use: 'mobile', value: order.patient.phone }];
  }

  const orderingClinician = buildOrderingClinician(order);
  const referringSite = buildReferringSite(order);

  // Represents the receiving laboratory, and this one DOES have to exist:
  // Task.owner is how OpenELIS finds orders addressed to it
  // (Task.OWNER.hasAnyOfIds(remoteStoreIdentifier)), so it is a routing
  // address, not a person — which is the substantive reason to type it as an
  // Organization quite apart from the requester it unblocks.
  //
  // The uuid must be a real row in OpenELIS's own `organization` table
  // (organization.fhir_uuid), so that the one place OpenELIS DOES emit this
  // reference — FhirReferralServiceImpl putting it on Task.restriction.recipient
  // for an outbound referral — names something that exists.
  const labOwner: FhirResource = {
    resourceType: 'Organization',
    id: labOwnerId,
    active: true,
    identifier: [{ system: `${OE_SYSTEM}/lab`, value: labOwnerId }],
    name: labOwnerName,
  };

  const specimen: FhirResource = {
    resourceType: 'Specimen',
    id: specimenId,
    status: 'available',
    subject: { reference: `Patient/${patientId}` },
    // receivedTime is NOT set.
    //
    // It used to carry order.createdAt, which told the laboratory it had
    // received a specimen at the moment the doctor clicked "order" — before
    // anyone had drawn blood. Receipt is an event the LABORATORY observes, in
    // its own building, and asserting it from here was a false statement in a
    // clinical record about someone else's premises.
    //
    // The collection time below is different: for an inpatient the ward
    // genuinely observed the draw, and is the only party that could.
    type: {
      coding: buildSpecimenCodings(order, specimenAbbreviation),
      text: order.specimenType,
    },
  };

  // The bedside draw, when the ward observed one. OpenELIS reads this on import
  // — addCollection takes collectedDateTime through to the accessioner's screen,
  // pre-filled, and on to sample_item.collection_date.
  //
  // Omitted entirely rather than sent empty when there is no time: an outpatient
  // specimen is drawn in the laboratory and its collection is the laboratory's
  // to record; an empty element would suggest we had something to say about it
  // and lost it.
  if (order.collectedAt) {
    specimen.collection = { collectedDateTime: order.collectedAt };
  }

  const serviceRequest: FhirResource = {
    resourceType: 'ServiceRequest',
    id: serviceRequestId,
    // OpenELIS reads identifier[0].value as electronic_order.external_id.
    identifier: [{ system: ORDER_NUMBER_SYSTEM, value: order.orderNumber }],
    // Populates "referring lab number" in the Incoming Orders view.
    requisition: { system: ORDER_NUMBER_SYSTEM, value: order.orderNumber },
    status: 'active',
    intent: 'order',
    priority: priorityOf(order.priority),
    code: {
      coding: [{ system: LOINC_SYSTEM, code: order.loincCode, display: order.testName }],
      text: order.testName,
    },
    subject: { reference: `Patient/${patientId}` },
    authoredOn: order.createdAt,
    specimen: [{ reference: `Specimen/${specimenId}` }],
  };

  // Absent when the HIS recorded no identified clinician. Absent is the honest
  // statement there; a reference to a Practitioner we invented would read as a
  // verified attribution.
  if (orderingClinician) {
    serviceRequest.requester = { reference: `Practitioner/${orderingClinician.id}` };
  }

  const task: FhirResource = {
    resourceType: 'Task',
    id: taskId,
    identifier: [{ system: ORDER_NUMBER_SYSTEM, value: order.orderNumber }],
    basedOn: [{ reference: `ServiceRequest/${serviceRequestId}` }],
    status: 'requested',
    intent: 'order',
    priority: priorityOf(order.priority),
    description: `${order.testName} (${order.testCode}) — order ${order.orderNumber}`,
    for: { reference: `Patient/${patientId}` },
    authoredOn: order.createdAt,
    owner: { reference: labOwnerReference },
  };

  // Absent when the HIS named no site, or named one with no display name.
  // OpenELIS dereferences this during import (getTaskLocationFromServer), so
  // the Location has to be readable before the Task is visible to a poll —
  // which the ordering of `all` below is what guarantees.
  if (referringSite) {
    task.location = { reference: `Location/${referringSite.id as string}` };
  }

  return {
    task,
    serviceRequest,
    patient,
    specimen,
    labOwner,
    orderingClinician,
    referringSite,
    all: [
      patient,
      labOwner,
      ...(orderingClinician ? [orderingClinician] : []),
      ...(referringSite ? [referringSite] : []),
      specimen,
      serviceRequest,
      task,
    ],
  };
};
