export interface ILabOrder {
  orderId: string;
  orderNumber: string;
  patientId: string;
  testCode: string;
  testName: string;
  orderStatus: string;
  orderingProvider: string;
  facilityCode: string;
  priority: string;
  statusDetail: string | null;
  /** Laboratory-side progress within ACCEPTED_BY_LIS. Null until the lab says so. */
  labProgress: string | null;
  labProgressAt: string | null;
  /** The laboratory's own accession number — what a ward quotes on the phone. */
  labAccession: string | null;
  createdAt: string | null;
  updatedAt: string | null;
}

export interface ICreateLabOrderInput {
  patientId: string;
  testCode: string;
  orderingProvider: string;
  facilityCode: string;
  priority?: string | undefined;
}

export interface IResultSummary {
  resultId: string;
  orderId: string;
  patientId: string;
  testCode: string;
  testName: string;
  resultValue: string | null;
  resultUnit: string | null;
  referenceRange: string | null;
  interpretation: string | null;
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
