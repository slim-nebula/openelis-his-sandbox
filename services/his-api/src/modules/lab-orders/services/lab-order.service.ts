import { NotFoundError } from '@core/exceptions/http.exceptions.js';
import { PatientsContainer } from '@modules/patients/containers/patients.container.js';
import { toIso } from '@shared/utils/serialization.utils.js';
import type { LabOrderModel } from '../models/lab-order.model.js';
import type {
  IBridgeOrderPayload,
  ICreateLabOrderInput,
  ILabOrder,
  IReleasedResultMessage,
  IResultSummary,
} from '../types/lab-order.types.js';

export class LabOrderService {
  constructor(private readonly orders: LabOrderModel) {}

  create(input: ICreateLabOrderInput, correlationId: string): Promise<ILabOrder> {
    return this.orders.create(input, correlationId);
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
      facilityCode: String(row.facility_code),
      priority: String(row.priority),
      createdAt: toIso(row.created_at),
      patient,
    };
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
}
