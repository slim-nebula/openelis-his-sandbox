import type { PoolClient } from 'pg';
import { query, queryOne, transaction, type Row } from '@config/db.js';
import type { FhirResource } from '@fhir/types.js';
import type { ITrackedOrderInsert } from '../types/order.types.js';

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
  /**
   * Publishes an order: every FHIR resource plus the tracking row, in ONE
   * transaction.
   *
   * Atomicity is the point. A half-written order is one OpenELIS could poll and
   * then fail to dereference — it would find a Task pointing at a
   * ServiceRequest that is not there yet, and the import would fail on the
   * laboratory's screen for a reason nobody could see from here.
   *
   * The resource upsert below is deliberately the SAME SQL as FhirModel.put,
   * duplicated rather than shared. The alternative is one model importing
   * another, and the reason this service splits BridgeStore.cs into a model per
   * module is that models import nothing of each other. A transaction spanning
   * two tables belongs to whichever module asks the question, and this question
   * — "record that this order has been published" — is the orders module's.
   * If the statement ever changes, both copies change.
   */
  async saveOrder(tracked: ITrackedOrderInsert, resources: FhirResource[]): Promise<void> {
    await transaction(async (client: PoolClient) => {
      for (const resource of resources) {
        await client.query(
          `INSERT INTO bridge.fhir_resources (resource_type, resource_id, version_id, content, last_updated)
           VALUES ($1, $2, 1, $3::jsonb, now())
           ON CONFLICT (resource_type, resource_id) DO UPDATE SET
               version_id   = bridge.fhir_resources.version_id + 1,
               content      = excluded.content,
               last_updated = now()`,
          [resource.resourceType, resource.id, JSON.stringify(resource)],
        );
      }

      await client.query(
        `INSERT INTO bridge.order_tracking
             (order_id, order_number, patient_id, test_code, loinc_code, fhir_task_id,
              fhir_servicerequest_id, fhir_patient_id, fhir_specimen_id, task_status,
              attempts, correlation_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
         ON CONFLICT (order_id) DO UPDATE SET
             task_status = excluded.task_status,
             attempts    = bridge.order_tracking.attempts + 1,
             updated_at  = now()`,
        [
          tracked.orderId,
          tracked.orderNumber,
          tracked.patientId,
          tracked.testCode,
          tracked.loincCode,
          tracked.fhirTaskId,
          tracked.fhirServiceRequestId,
          tracked.fhirPatientId,
          tracked.fhirSpecimenId,
          tracked.taskStatus,
          tracked.attempts,
          tracked.correlationId,
        ],
      );
    });
  }

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
