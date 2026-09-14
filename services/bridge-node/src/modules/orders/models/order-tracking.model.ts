import { query, queryOne, type Row } from '@config/db.js';

/**
 * What the bridge knows about an order it has published: which FHIR resources
 * stand for it, where the laboratory has got to with it, and the correlation id
 * that ties the whole journey together.
 *
 * Phase 2b uses only the two reads the FHIR update route needs — telling
 * OpenELIS's verdict on OUR order apart from OpenELIS pushing us a resource.
 * The consumer that writes these rows arrives in phase 3.
 */
export interface TrackedOrder {
  orderId: string;
  orderNumber: string;
  patientId: string;
  testCode: string;
  loincCode: string;
  fhirTaskId: string;
  fhirServiceRequestId: string;
  fhirPatientId: string;
  fhirSpecimenId: string | null;
  taskStatus: string;
  attempts: number;
  correlationId: string | null;
}

const toTracked = (row: Row): TrackedOrder => ({
  orderId: String(row.order_id),
  orderNumber: String(row.order_number),
  patientId: String(row.patient_id),
  testCode: String(row.test_code),
  loincCode: String(row.loinc_code),
  fhirTaskId: String(row.fhir_task_id),
  fhirServiceRequestId: String(row.fhir_servicerequest_id),
  fhirPatientId: String(row.fhir_patient_id),
  fhirSpecimenId: row.fhir_specimen_id === null ? null : String(row.fhir_specimen_id),
  taskStatus: String(row.task_status),
  attempts: Number(row.attempts),
  correlationId: row.correlation_id === null ? null : String(row.correlation_id),
});

const COLUMNS = `order_id, order_number, patient_id, test_code, loinc_code, fhir_task_id,
                 fhir_servicerequest_id, fhir_patient_id, fhir_specimen_id, task_status,
                 attempts, correlation_id`;

export class OrderTrackingModel {
  async byTaskId(taskId: string): Promise<TrackedOrder | null> {
    const row = await queryOne<Row>(
      `SELECT ${COLUMNS} FROM bridge.order_tracking WHERE fhir_task_id = $1`,
      [taskId],
    );
    return row ? toTracked(row) : null;
  }

  async setTaskStatus(taskId: string, status: string): Promise<void> {
    await query(
      `UPDATE bridge.order_tracking SET task_status = $2, updated_at = now()
        WHERE fhir_task_id = $1`,
      [taskId, status],
    );
  }
}
