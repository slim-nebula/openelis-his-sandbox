export interface ILabOrder {
  orderId: string;
  orderNumber: string;
  patientId: string;
  testCode: string;
  testName: string;
  orderStatus: string;
  orderingProvider: string;
  /** usr_id of the authenticated clinician. Null only for pre-identity orders. */
  orderingProviderId: string | null;
  facilityCode: string;
  priority: string;
  /**
   * The encounter this order was placed during. Null for orders predating the
   * column. Never sent to OpenELIS — a returning result is filed against it by
   * order correlation, so it never has to survive a trip through the laboratory.
   */
  visitNumber: string | null;
  statusDetail: string | null;
  /** Laboratory-side progress within ACCEPTED_BY_LIS. Null until the lab says so. */
  labProgress: string | null;
  labProgressAt: string | null;
  /** The laboratory's own accession number — what a ward quotes on the phone. */
  labAccession: string | null;
  createdAt: string | null;
  updatedAt: string | null;
}

/**
 * What the caller may ask for.
 *
 * Note what is absent: the ordering provider. It is not the caller's to state —
 * it is read from the verified token by the controller, which is the only place
 * that knows it for certain.
 */
export interface ICreateLabOrderInput {
  patientId: string;
  testCode: string;
  facilityCode: string;
  priority?: string | undefined;
  /** Which visit the doctor is in. Supplied by the caller; see 009_visit_number.sql. */
  visitNumber?: string | undefined;
}

/** Who placed the order, established from the token rather than the payload. */
export interface IOrderingClinician {
  id: string;
  name: string;
}

export interface IResultSummary {
  resultId: string;
  orderId: string;
  /** The order number the laboratory knew this by. */
  orderNumber: string | null;
  patientId: string;
  /**
   * The encounter this result belongs to, so the caller can file it against the
   * right visit rather than only the right patient. Joined from the order
   * rather than stored on the result, so it cannot disagree with its source.
   * Null for orders placed before the visit was recorded.
   *
   * The patient's file number is deliberately not carried: the calling HIS owns
   * the patient record and resolves it from patientId.
   */
  visitNumber: string | null;
  testCode: string;
  testName: string;
  /**
   * Which specimen this test was run on, joined from the catalogue.
   *
   * Not decoration. Two orders for the same LOINC on different specimens share
   * a test_name — "HIV VIRAL LOAD" for both plasma and dried blood spot — and
   * are different examinations with different methods and different reference
   * ranges. Without this a clinician cannot tell them apart on screen.
   *
   * Null only if the catalogue entry has since been withdrawn.
   */
  specimenType: string | null;
  resultValue: string | null;
  resultUnit: string | null;
  referenceRange: string | null;
  interpretation: string | null;
  /**
   * The HL7 v3 ObservationInterpretation code behind `interpretation`:
   * N, A, H, L for the ordinary cases and AA, HH, LL for the critical ones.
   *
   * Carried separately because `interpretation` is a display string the
   * laboratory is free to reword, and a severity treatment that pattern-matches
   * on words fails silently the day the wording changes — losing the red on a
   * critical result, which is the one failure mode that must not be quiet.
   */
  interpretationCode: string | null;
  /**
   * The value this result replaced, when it is a correction or an amendment.
   *
   * A clinician may have already acted on the superseded value, and needs it to
   * judge whether that decision still holds — the requirement in ISO 15189
   * 7.4.1.8 that a revised report reference what it revises. Recovered from the
   * lab_order_events audit trail rather than a second stored copy.
   */
  previousValue: string | null;
  previousReleasedAt: string | null;
  resultStatus: string;
  releasedAt: string | null;
  openelisResultRef: string;
  receivedAt: string | null;
}

/** Everything the bridge needs to build a FHIR order, in one response. */
export interface IBridgeOrderPayload {
  orderId: string;
  orderNumber: string;
  testCode: string;
  testName: string;
  loincCode: string;
  specimenType: string;
  specimenSnomed: string | null;
  resultUnit: string | null;
  orderStatus: string;
  orderingProvider: string;
  /**
   * Sent so the bridge can key the FHIR Practitioner off a stable id instead of
   * a hash of the display name — which made every spelling of a clinician's
   * name a different practitioner in the laboratory's records.
   */
  orderingProviderId: string | null;
  facilityCode: string;
  priority: string;
  createdAt: string | null;
  patient: unknown;
}

export interface IReleasedResultMessage {
  eventId?: string;
  correlationId?: string | null;
  orderNumber: string;
  openelisResultRef: string;
  testCode?: string | null;
  testName?: string | null;
  resultValue?: string | null;
  resultUnit?: string | null;
  referenceRange?: string | null;
  interpretation?: string | null;
  /** HL7 v3 ObservationInterpretation code; see IResultSummary. */
  interpretationCode?: string | null;
  resultStatus: string;
  releasedAt: string;
}

/** Where an order has got to inside the laboratory. See ProgressTracker.cs. */
export interface ILabProgressMessage {
  eventId?: string;
  correlationId?: string | null;
  orderNumber: string;
  progress: string;
  accessionNumber?: string | null;
  occurredAt?: string;
}

export interface IOrderLifecycleMessage {
  eventId?: string;
  correlationId?: string | null;
  orderNumber: string;
  status: string;
  detail?: string | null;
}
