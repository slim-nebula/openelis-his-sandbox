import type { FhirResource } from '@fhir/types.js';

/** The HIS order payload, exactly as /internal/lab-orders/{id} returns it. */
export interface IHisOrder {
  orderId: string;
  orderNumber: string;
  testCode: string;
  testName: string;
  loincCode: string;
  specimenType: string;
  specimenSnomed: string | null;
  resultUnit: string | null;
  orderStatus: string;
  /**
   * Who placed the order, from the verified token — never the request body
   * (db/his/008). The display name goes on the laboratory's report.
   */
  orderingProvider: string | null;
  /**
   * The ACCOUNT that acted. Carried for completeness and NOT used as the
   * Practitioner key: it is nullable and non-unique in the source system, and
   * the rest of the clinical record does not identify doctors this way.
   */
  orderingProviderId: string | null;
  /**
   * The CLINICIAN — mlh_his_hcp_health_care_provider.id — and what the FHIR
   * Practitioner identity is actually derived from, so that one clinician stays
   * one clinician however their name is spelled and whether or not they have a
   * login. See db/his/015_provider_identity.sql.
   *
   * Null is a real answer, not a gap to fill: a receptionist has an account and
   * no clinical identity, and rows predating 015 have neither. The bridge then
   * sends no requester at all rather than substituting the account.
   */
  orderingProviderHcpId: string | null;
  /**
   * Their licence number, published as a second identifier because a laboratory
   * recognises a licence where an internal id means nothing.
   */
  orderingProviderLicense: string | null;
  facilityCode: string;
  /**
   * The site's display name, which becomes Location.name and — on first import —
   * the name of the organization OpenELIS creates for it.
   *
   * Null is a real answer and is handled by publishing no Location at all. A
   * Location with no name still creates the organization, because OpenELIS
   * guards only the name assignment (`if (location.hasName())`), leaving a
   * nameless row the accessioner sees as a blank Referring Site — which looks
   * like a rendering fault rather than missing data.
   */
  facilityName: string | null;
  priority: string;
  /**
   * OUTPATIENT or INPATIENT. Only the inpatient path carries a collection time
   * outward: an outpatient specimen is drawn in the laboratory, which observes
   * that collection and reports it back to us instead.
   */
  patientClass: string | null;
  /**
   * When the WARD drew the specimen, for an inpatient order. Goes onto
   * Specimen.collection.collectedDateTime, which OpenELIS reads on import
   * (LabOrderSearchProvider.addCollection) and pre-fills onto the accessioner's
   * screen. Null for an outpatient order, and null is correct there rather than
   * missing.
   */
  collectedAt: string | null;
  createdAt: string;
  patient: IHisPatient;
}

export interface IHisPatient {
  patientId: string;
  firstName: string;
  lastName: string;
  sex: string;
  dateOfBirth: string;
  phone: string | null;
  nationalId: string | null;
}

// The patient's file number (MRN) is NOT sent, and the reason has been narrowed
// to the one that actually holds.
//
// It is NOT that "OpenELIS discards it". That was recorded earlier and is
// false: an attempt had carried the file number on a type coding with no
// system, and OpenELIS matches identifiers by SYSTEM. Sending it as
// .../pat_subjectNumber works — verified end to end, it lands as the SUBJECT
// identity and shows on the accessioning screen as "Unique Health ID number".
//
// It is that the HIS can resolve the folder number from the patient id in its
// own records, so shipping it would put a second copy of one fact into another
// system, with somewhere new for it to drift. One identifier crosses the
// boundary for the patient, and that is deliberate.

export interface IOrderCreatedEvent {
  eventId?: string | null;
  correlationId?: string | null;
  orderId: string;
  orderNumber: string;
  patientId?: string;
  testCode?: string;
}

export interface IMappedOrder {
  task: FhirResource;
  serviceRequest: FhirResource;
  patient: FhirResource;
  specimen: FhirResource;
  labOwner: FhirResource;
  orderingClinician: FhirResource | null;
  /**
   * The referring site, as a Location. Null when the HIS gave us no site name.
   *
   * Unlike every other resource here this one has a side effect in the
   * laboratory's own records: OpenELIS creates a referring-clinic organization
   * from it the first time it sees the uuid. That is the point — it retires the
   * hand-typing at accessioning — but it means a bad site list becomes a bad
   * clinic list, so the name is worth validating before it is sent.
   */
  referringSite: FhirResource | null;
  /**
   * Publication order matters: OpenELIS dereferences ServiceRequest.requester
   * while importing, so the Practitioner has to be readable before the
   * ServiceRequest that points at it is visible to a poll. The Location is read
   * from Task.location during the same import and goes out on the same rule.
   */
  all: FhirResource[];
}

/** What gets written to bridge.order_tracking when an order is published. */
export interface ITrackedOrderInsert {
  orderId: string;
  orderNumber: string;
  patientId: string;
  testCode: string;
  loincCode: string;
  fhirTaskId: string;
  fhirServiceRequestId: string;
  fhirPatientId: string;
  fhirSpecimenId: string;
  taskStatus: string;
  attempts: number;
  correlationId: string | null;
}
