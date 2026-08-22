import { randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import { query, queryOne, transaction, type Row } from '@config/db.js';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { DomainError } from '@core/exceptions/http.exceptions.js';
import { toIso } from '@shared/utils/serialization.utils.js';
import type {
  ICreateLabOrderInput,
  ILabOrder,
  IReleasedResultMessage,
  IResultSummary,
} from '../types/lab-order.types.js';

const ORDER_COLUMNS = `order_id, order_number, patient_id, test_code, test_name, order_status,
                       ordering_provider, facility_code, priority, status_detail,
                       created_at, updated_at`;

const RESULT_COLUMNS = `result_id, order_id, patient_id, test_code, test_name, result_value,
                        result_unit, reference_range, interpretation, result_status,
                        released_at, openelis_result_ref, received_at`;

const toOrder = (row: Row): ILabOrder => ({
  orderId: String(row.order_id),
  orderNumber: String(row.order_number),
  patientId: String(row.patient_id),
  testCode: String(row.test_code),
  testName: String(row.test_name),
  orderStatus: String(row.order_status),
  orderingProvider: String(row.ordering_provider),
  facilityCode: String(row.facility_code),
  priority: String(row.priority),
  statusDetail: row.status_detail === null ? null : String(row.status_detail),
  createdAt: toIso(row.created_at),
  updatedAt: toIso(row.updated_at),
});

const toResult = (row: Row): IResultSummary => ({
  resultId: String(row.result_id),
  orderId: String(row.order_id),
  patientId: String(row.patient_id),
  testCode: String(row.test_code),
  testName: String(row.test_name),
  resultValue: row.result_value === null ? null : String(row.result_value),
  resultUnit: row.result_unit === null ? null : String(row.result_unit),
  referenceRange: row.reference_range === null ? null : String(row.reference_range),
  interpretation: row.interpretation === null ? null : String(row.interpretation),
  resultStatus: String(row.result_status),
  releasedAt: toIso(row.released_at),
  openelisResultRef: String(row.openelis_result_ref),
  receivedAt: toIso(row.received_at),
});

const appendEvent = async (
  client: PoolClient,
  orderId: string,
  type: string,
  detail: string | null,
  correlationId: string | null,
  payloadJson: string | null,
): Promise<void> => {
  await client.query(
    `INSERT INTO his.lab_order_events (order_id, event_type, detail, correlation_id, payload)
     VALUES ($1, $2, $3, $4, $5::jsonb)`,
    [orderId, type, detail, correlationId, payloadJson],
  );
};

export class LabOrderModel {
  /**
   * Creates the order, its audit row, and the lab.order.created event in ONE
   * transaction.
   *
   * Nothing here touches Kafka. The outbox relay publishes, and that separation
   * is the whole point: a single commit decides whether the order and its event
   * both exist. Publishing inside the request instead would mean a broker
   * outage — or a crash in the gap — leaving an order that the laboratory never
   * hears about, with nothing logged as failed anywhere.
   */
  async create(input: ICreateLabOrderInput, correlationId: string): Promise<ILabOrder> {
    return transaction(async (client) => {
      const test = await client.query(
        `SELECT test_code, test_name, loinc_code FROM his.test_catalogue
          WHERE test_code = $1 AND is_active`,
        [input.testCode],
      );
      if (test.rowCount === 0) {
        throw new DomainError(`Unknown or inactive test code '${input.testCode}'.`);
      }
      const testRow = test.rows[0] as Row;

      const patient = await client.query(
        'SELECT exists(SELECT 1 FROM his.patients WHERE patient_id = $1) AS present',
        [input.patientId],
      );
      if ((patient.rows[0] as Row).present !== true) {
        throw new DomainError(`Unknown patient '${input.patientId}'.`);
      }

      const orderId = randomUUID();
      // <= 60 characters: OpenELIS truncates electronic_order.external_id there.
      const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
      const orderNumber = `LAB-${stamp}-${orderId.replace(/-/g, '').slice(0, 8).toUpperCase()}`;

      const inserted = await client.query(
        `INSERT INTO his.lab_orders
             (order_id, order_number, patient_id, test_code, test_name, order_status,
              ordering_provider, facility_code, priority, correlation_id)
         VALUES ($1, $2, $3, $4, $5, 'CREATED', $6, $7, $8, $9)
         RETURNING ${ORDER_COLUMNS}`,
        [
          orderId,
          orderNumber,
          input.patientId,
          String(testRow.test_code),
          String(testRow.test_name),
          input.orderingProvider,
          input.facilityCode,
          input.priority ?? 'routine',
          correlationId,
        ],
      );

      await appendEvent(
        client,
        orderId,
        'ORDER_CREATED',
        `Order created for test ${String(testRow.test_code)}`,
        correlationId,
        null,
      );

      const payload = JSON.stringify({
        eventId: randomUUID(),
        eventType: 'lab.order.created',
        occurredAt: new Date().toISOString(),
        correlationId,
        orderId,
        orderNumber,
        patientId: input.patientId,
        testCode: String(testRow.test_code),
        loincCode: String(testRow.loinc_code),
      });

      await client.query(
        `INSERT INTO his.outbox
             (event_id, aggregate_type, aggregate_id, topic, partition_key, payload, correlation_id)
         VALUES ($1, 'lab_order', $2, $3, $4, $5::jsonb, $6)`,
        [randomUUID(), orderId, config.kafka.topics.orderCreated, orderId, payload, correlationId],
      );

      logger.info(
        `Order ${orderNumber} created for patient ${input.patientId} (correlation ${correlationId})`,
      );
      return toOrder(inserted.rows[0] as Row);
    });
  }

  async findById(orderId: string): Promise<ILabOrder | null> {
    const row = await queryOne<Row>(
      `SELECT ${ORDER_COLUMNS} FROM his.lab_orders WHERE order_id = $1`,
      [orderId],
    );
    return row ? toOrder(row) : null;
  }

  async listForPatient(patientId: string): Promise<ILabOrder[]> {
    const rows = await query<Row>(
      `SELECT ${ORDER_COLUMNS} FROM his.lab_orders WHERE patient_id = $1 ORDER BY created_at DESC`,
      [patientId],
    );
    return rows.map(toOrder);
  }

  async bridgePayload(orderId: string): Promise<Row | null> {
    return queryOne<Row>(
      `SELECT o.order_id, o.order_number, o.test_code, o.test_name,
              c.loinc_code, c.specimen_type, c.specimen_snomed, c.result_unit,
              o.order_status, o.ordering_provider, o.facility_code, o.priority,
              o.created_at, o.patient_id
         FROM his.lab_orders o
         JOIN his.test_catalogue c ON c.test_code = o.test_code
        WHERE o.order_id = $1`,
      [orderId],
    );
  }

  /**
   * OpenELIS updates the same Task more than once — received, then accepted —
   * and the bridge relays each. `IS DISTINCT FROM` means only a genuine change
   * writes an audit row, so the trail stays a history of the order rather than
   * a log of how chatty the LIS was.
   */
  async updateStatus(
    orderNumber: string,
    status: string,
    detail: string | null,
    correlationId: string | null,
  ): Promise<void> {
    await transaction(async (client) => {
      const changed = await client.query(
        `UPDATE his.lab_orders
            SET order_status = $2, status_detail = $3, updated_at = now()
          WHERE order_number = $1
            AND order_status IS DISTINCT FROM $2
        RETURNING order_id`,
        [orderNumber, status, detail],
      );

      if (changed.rowCount === 0) {
        const exists = await client.query(
          'SELECT exists(SELECT 1 FROM his.lab_orders WHERE order_number = $1) AS present',
          [orderNumber],
        );
        if ((exists.rows[0] as Row).present !== true) {
          logger.warn(`Status update for unknown order ${orderNumber} ignored`);
        }
        return;
      }

      const orderId = String((changed.rows[0] as Row).order_id);
      await appendEvent(client, orderId, status, detail, correlationId, null);
    });
  }

  /**
   * Idempotent on the OpenELIS record reference: a replayed release for the same
   * result updates the projection instead of duplicating it.
   */
  async upsertResult(message: IReleasedResultMessage): Promise<boolean> {
    return transaction(async (client) => {
      const found = await client.query(
        `SELECT order_id, patient_id, test_code, test_name
           FROM his.lab_orders WHERE order_number = $1`,
        [message.orderNumber],
      );
      if (found.rowCount === 0) {
        logger.warn(`Released result for unknown order ${message.orderNumber} ignored`);
        return false;
      }
      const order = found.rows[0] as Row;

      await client.query(
        `INSERT INTO his.lab_results_summary
             (result_id, order_id, patient_id, test_code, test_name, result_value,
              result_unit, reference_range, interpretation, result_status,
              released_at, openelis_result_ref)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
         ON CONFLICT (openelis_result_ref) DO UPDATE SET
             result_value    = excluded.result_value,
             result_unit     = excluded.result_unit,
             reference_range = excluded.reference_range,
             interpretation  = excluded.interpretation,
             result_status   = excluded.result_status,
             released_at     = excluded.released_at,
             received_at     = now()`,
        [
          randomUUID(),
          order.order_id,
          order.patient_id,
          message.testCode ?? order.test_code,
          message.testName ?? order.test_name,
          message.resultValue ?? null,
          message.resultUnit ?? null,
          message.referenceRange ?? null,
          message.interpretation ?? null,
          message.resultStatus,
          message.releasedAt,
          message.openelisResultRef,
        ],
      );

      await client.query(
        `UPDATE his.lab_orders SET order_status = 'RESULT_AVAILABLE', updated_at = now()
          WHERE order_id = $1`,
        [order.order_id],
      );

      await client.query(
        `INSERT INTO his.integration_mappings
             (his_entity_type, his_id, external_system, external_type, external_id)
         VALUES ('result', $1, 'openelis', 'DiagnosticReport', $2)
         ON CONFLICT (his_entity_type, his_id, external_system, external_type) DO NOTHING`,
        [String(order.order_id), message.openelisResultRef],
      );

      await appendEvent(
        client,
        String(order.order_id),
        'RESULT_RECEIVED',
        `Released result ${message.openelisResultRef} stored`,
        message.correlationId ?? null,
        JSON.stringify(message),
      );

      logger.info(
        `Stored released result ${message.openelisResultRef} for order ${message.orderNumber}`,
      );
      return true;
    });
  }

  async resultsForPatient(patientId: string): Promise<IResultSummary[]> {
    const rows = await query<Row>(
      `SELECT ${RESULT_COLUMNS} FROM his.lab_results_summary
        WHERE patient_id = $1 ORDER BY released_at DESC`,
      [patientId],
    );
    return rows.map(toResult);
  }

  async resultsForOrder(orderId: string): Promise<IResultSummary[]> {
    const rows = await query<Row>(
      `SELECT ${RESULT_COLUMNS} FROM his.lab_results_summary
        WHERE order_id = $1 ORDER BY released_at DESC`,
      [orderId],
    );
    return rows.map(toResult);
  }
}
