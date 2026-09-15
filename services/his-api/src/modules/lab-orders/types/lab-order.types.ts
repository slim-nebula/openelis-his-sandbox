export interface ILabOrder {
  orderId: string;
  orderNumber: string;
  patientId: string;
  testCode: string;
  testName: string;
  orderStatus: string;
  orderingProvider: string;
  /** usr_id of the authenticated ACCOUNT. Null only for pre-identity orders. */
  orderingProviderId: string | null;
  /**
   * The ordering clinician's CLINICAL identity —
   * mlh_his_hcp_health_care_provider.id in the real HIS. This is what the
   * laboratory is told; orderingProviderId is what the audit trail keeps. Null
   * when the signed-in user has no provider row.
   */
  orderingProviderHcpId: string | null;
  /** Their licence number, sent to the laboratory as a second identifier. */
  orderingProviderLicense: string | null;
  facilityCode: string;
  priority: string;
  /**
   * The encounter this order was placed during. Null for orders predating the
   * column. Never sent to OpenELIS — a returning result is filed against it by
   * order correlation, so it never has to survive a trip through the laboratory.
   */
  visitNumber: string | null;
  /**
   * OUTPATIENT — the patient goes to the laboratory and a technician draws the
   * blood there, so the laboratory observes the collection and reports it back.
   *
   * INPATIENT — a nurse draws at the bedside and nobody in the laboratory sees
   * it. The order is held at AWAITING_COLLECTION until the ward records the
   * draw, then dispatches carrying the collection time.
   */
  patientClass: string;
  /**
   * When the ward drew the specimen. Inpatient orders only, and null until the
   * nurse records it — which is also what releases the order to the laboratory.
   */
  collectedAt: string | null;
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
  /**
   * OUTPATIENT (the default) or INPATIENT. Context the calling HIS knows and we
   * do not — like the visit, and unlike the ordering clinician, which is an
   * identity claim the caller must not make.
   *
   * It decides the workflow: an outpatient order dispatches immediately and the
   * laboratory reports the collection time back; an inpatient order waits for
   * the ward to record the draw and carries that time outward.
   */
  patientClass?: string | undefined;
}

/**
 * A site a doctor may order from — clinic, ward, emergency department.
 *
 * This is what the laboratory calls the **Referring Site**: who sent the sample,
 * where the report goes back, and who they telephone about a problem. Their
 * accessioning wizard requires it, and today a technician types it on every
 * order because we send nothing.
 *
 * Sandbox stand-in. In a real HIS it comes off the visit or from
 * business_unit_id — see 014_facilities.sql.
 */
export interface IFacility {
  facilityCode: string;
  facilityName: string;
  /** CLINIC | WARD | EMERGENCY | OUTPATIENT — the part a laboratory acts on. */
  facilityType: string;
}

/** Recording a bedside draw. See 013_specimen_collection.sql. */
export interface IRecordCollectionInput {
  /** ISO-8601. Must not be in the future; a draw is a thing that has happened. */
  collectedAt: string;
}

/**
 * Who placed the order, established from the token rather than the payload.
 *
 * Two identities, because two systems ask different questions. `id` is the
 * ACCOUNT that acted and is what an audit trail needs. `hcpId` is the CLINICIAN
 * who is accountable for the test and is what the laboratory is told. In the
 * real HIS they live in different services — IAM and org-setup — and one can
 * exist without the other. See db/his/015_provider_identity.sql.
 */
export interface IOrderingClinician {
  /** usr_id from the verified token. Always present. */
  id: string;
  /** usr_full_name — what a laboratory report prints. */
  name: string;
  /**
   * mlh_his_hcp_health_care_provider.id. Absent when the signed-in user has no
   * provider row, in which case no clinician is published rather than one being
   * invented from the account.
   */
  hcpId?: string | undefined;
  /** The clinician's licence number, when recorded. */
  license?: string | undefined;
}

/**
 * One analyte inside a released report.
 *
 * A full blood count is one report and eight of these. Before
 * db/his/016_result_components.sql the bridge forwarded only the first
 * Observation, so a panel arrived as a single number with nothing indicating the
 * other seven had been dropped.
 */
export interface IResultComponent {
  /**
   * The analyte's own code — LOINC where the laboratory supplied one. Null when
   * it sent no coding at all, which is legal and leaves the name as the only
   * identification.
   */
  analyteCode: string | null;
  analyteName: string;
  resultValue: string | null;
  resultUnit: string | null;
  referenceRange: string | null;
  interpretation: string | null;
  /**
   * Per-analyte severity, and the reason components cannot share the report's.
   * A metabolic panel can be normal in six analytes and critically high in the
   * seventh, and that seventh is the whole clinical point of the report.
   */
  interpretationCode: string | null;
  /** Zero-based, in the order the laboratory released them. */
  position: number;
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
  /**
   * When the specimen was drawn — the time a clinician needs in order to judge
   * whether this value still describes the patient. `releasedAt` alone cannot
   * answer that: a result signed out five minutes ago may be from blood taken
   * six hours ago (ISO 15189:2022 7.4.1.7.a).
   *
   * Whoever observed the draw is the source, so this coalesces the ward's
   * record first and the laboratory's second — we never depend on a round trip
   * for a fact we already hold. Null when nobody wrote it down, and it MUST be
   * displayed as "not recorded" rather than falling back to a received or
   * released time: an invented collection time is indistinguishable from an
   * observed one, and a clinician will act on it.
   */
  collectedAt: string | null;
  /** 'ward' | 'laboratory' | null — which system observed the draw. */
  collectionSource: string | null;
  /**
   * The laboratory's own number for this work — what a ward is asked for on the
   * telephone. `orderNumber` identifies the order in OUR system; this identifies
   * it in THEIRS, and only one of those is useful to the person who answers.
   *
   * Null until a lab user accessions the sample: no accession number exists
   * before the laboratory has taken the specimen in. Joined from the order, so
   * it cannot disagree with the order it belongs to.
   */
  labAccession: string | null;
  resultStatus: string;
  releasedAt: string | null;
  openelisResultRef: string;
  receivedAt: string | null;
  /**
   * Every analyte the report carried, in released order.
   *
   * A single-analyte result has exactly one element, whose values equal the flat
   * fields above — those remain the report-level answer and are not deprecated.
   * A panel has one element per component, and the flat fields then hold the
   * FIRST of them, so a consumer that predates panels still gets a sensible
   * answer instead of a broken one.
   *
   * Empty for a retracted result: there is no value to carry, only the
   * withdrawal.
   */
  components: IResultComponent[];
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
   * The ACCOUNT that placed the order. Kept for the audit trail; the bridge no
   * longer keys the laboratory's Practitioner on it.
   */
  orderingProviderId: string | null;
  /**
   * What the bridge DOES key the FHIR Practitioner on — the clinician's own id,
   * stable and unique, rather than the account's or a hash of the display name.
   * A name-derived identity made every spelling of one clinician a different
   * practitioner in the laboratory's records; an account-derived one leaves out
   * every clinician who has no login. See db/his/015_provider_identity.sql.
   */
  orderingProviderHcpId: string | null;
  /** Their licence number, published as a second Practitioner identifier. */
  orderingProviderLicense: string | null;
  facilityCode: string;
  /**
   * The site's display name, for the referring Location the bridge publishes.
   * Null when the site has been retired since the order was placed.
   */
  facilityName: string | null;
  priority: string;
  /** OUTPATIENT or INPATIENT — see 013_specimen_collection.sql. */
  patientClass: string;
  /**
   * The bedside draw time, for an inpatient order. The bridge puts it on
   * Specimen.collection.collectedDateTime, which OpenELIS reads on import and
   * pre-fills onto the accessioner's screen. Null for an outpatient order: the
   * laboratory observes that draw and reports it back instead.
   */
  collectedAt: string | null;
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
  /**
   * Collection time as the LABORATORY observed it, read from
   * Specimen.collection.collected on the Specimen the DiagnosticReport
   * references.
   *
   * Never from Observation.effective: OpenELIS sets that to
   * analysis.getReleasedDate() (FhirTransformServiceImpl), so a reader
   * following the FHIR convention that `effective` means collection time gets
   * the release time instead — a plausible timestamp, hours wrong, with
   * nothing failing.
   */
  labCollectedAt?: string | null;
  resultStatus: string;
  releasedAt: string;
  /**
   * Every analyte in the report, in released order, as the bridge resolved them
   * from DiagnosticReport.result.
   *
   * Optional on the wire so a message produced by an older bridge still parses:
   * absent means "this producer does not send components", and the receiver
   * falls back to synthesising one component from the flat fields. Present and
   * empty is a different statement — a retraction, which has no analytes.
   */
  observations?: IReleasedObservation[] | undefined;
}

/** One analyte as it arrives on lab.result.released. */
export interface IReleasedObservation {
  position: number;
  code?: string | null;
  name?: string | null;
  value?: string | null;
  unit?: string | null;
  referenceRange?: string | null;
  interpretation?: string | null;
  interpretationCode?: string | null;
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
