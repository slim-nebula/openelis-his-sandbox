import { NotFoundError } from '@core/exceptions/http.exceptions.js';
import { PatientsContainer } from '@modules/patients/containers/patients.container.js';
import { toIso } from '@shared/utils/serialization.utils.js';
import type { LabOrderModel } from '../models/lab-order.model.js';
import type {
  IBridgeOrderPayload,
  ICreateLabOrderInput,
  IFacility,
  ILabOrder,
  IOrderingClinician,
  IReleasedResultMessage,
  IResultSummary,
} from '../types/lab-order.types.js';

export class LabOrderService {
  constructor(private readonly orders: LabOrderModel) {}

  create(
    input: ICreateLabOrderInput,
    clinician: IOrderingClinician,
    correlationId: string,
  ): Promise<ILabOrder> {
    return this.orders.create(input, clinician, correlationId);
  }

  async getWithResults(orderId: string): Promise<{ order: ILabOrder; results: IResultSummary[] }> {
    const order = await this.orders.findById(orderId);
    if (!order) throw new NotFoundError(`Unknown order '${orderId}'.`);
    return { order, results: await this.orders.resultsForOrder(orderId) };
  }

  listForPatient(patientId: string): Promise<ILabOrder[]> {
    return this.orders.listForPatient(patientId);
  }

  resultsForPatient(patientId: string): Promise<IResultSummary[]> {
    return this.orders.resultsForPatient(patientId);
  }

  resultsForVisit(visitNumber: string): Promise<IResultSummary[]> {
    return this.orders.resultsForVisit(visitNumber);
  }

  /**
   * The payload the bridge fetches after consuming lab.order.created.
   *
   * The event carries ids only — no names, no date of birth. That is
   * deliberate: putting demographics on a Kafka topic would replicate patient
   * data to every consumer, keep it for the topic's retention, and serve a
   * stale copy after any correction. So the bridge is told WHICH order, and
   * reads the details here, over the sandbox network, at the moment it needs
   * them.
   */
  async bridgePayload(orderId: string): Promise<IBridgeOrderPayload | null> {
    const row = await this.orders.bridgePayload(orderId);
    if (!row) return null;

    const patient = await PatientsContainer.patientModel.findById(String(row.patient_id));
    if (!patient) return null;

    return {
      orderId: String(row.order_id),
      orderNumber: String(row.order_number),
      testCode: String(row.test_code),
      testName: String(row.test_name),
      loincCode: String(row.loinc_code),
      specimenType: String(row.specimen_type),
      specimenSnomed: row.specimen_snomed === null ? null : String(row.specimen_snomed),
      resultUnit: row.result_unit === null ? null : String(row.result_unit),
      orderStatus: String(row.order_status),
      orderingProvider: String(row.ordering_provider),
      orderingProviderId: row.ordering_provider_id === null || row.ordering_provider_id === undefined
        ? null : String(row.ordering_provider_id),
      facilityCode: String(row.facility_code),
      priority: String(row.priority),
      patientClass: String(row.patient_class ?? 'OUTPATIENT'),
      collectedAt: toIso(row.collected_at),
      createdAt: toIso(row.created_at),
      patient,

    };
  }

  /** The sites a doctor may order from. Sandbox stand-in; see 014_facilities.sql. */
  listFacilities(): Promise<IFacility[]> {
    return this.orders.listFacilities();
  }

  /**
   * Records a bedside draw and releases the order the ward was holding.
   *
   * Only meaningful for an inpatient order: an outpatient specimen is drawn in
   * the laboratory, which observes the collection and reports it back, so
   * recording it here would manufacture a second version of one fact.
   */
  recordCollection(
    orderNumber: string,
    collectedAt: Date,
    correlationId: string,
  ): Promise<ILabOrder> {
    return this.orders.recordCollection(orderNumber, collectedAt, correlationId);
  }

  storeResult(message: IReleasedResultMessage): Promise<boolean> {
    return this.orders.upsertResult(message);
  }

  updateStatus(
    orderNumber: string,
    status: string,
    detail: string | null,
    correlationId: string | null,
  ): Promise<void> {
    return this.orders.updateStatus(orderNumber, status, detail, correlationId);
  }

  /** Laboratory-side progress. Advances only — see the model. */
  recordProgress(
    orderNumber: string,
    progress: string,
    accessionNumber: string | null,
    correlationId: string | null,
  ): Promise<void> {
    return this.orders.recordProgress(orderNumber, progress, accessionNumber, correlationId);
  }
}
