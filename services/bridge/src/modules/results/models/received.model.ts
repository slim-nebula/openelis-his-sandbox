import { query, queryOne, type Row } from '@config/db.js';
import type { FhirResource } from '@fhir/types.js';
import { toIso } from '@shared/utils/serialization.utils.js';

/**
 * Reading back what OpenELIS pushed.
 *
 * DECIMALS ARE READ AS TEXT, AND THIS IS THE REASON THE RULE EXISTS.
 *
 * Everything here reads `received_resources`, which is where RESULTS live —
 * and node-postgres parses a jsonb column into JavaScript values, where there
 * is one number type. A potassium the analyser reported as 4.0 becomes 4, and a
 * haemoglobin of 12.10 becomes 12.1. Nothing errors; the HIS simply shows a
 * number with fewer significant figures than the laboratory measured.
 *
 * The .NET service did not have this problem because it parsed into a type with
 * real decimals. Here, the precision-critical scalars are pulled out separately
 * with `->>`, which asks Postgres for the jsonb numeric AS TEXT and returns
 * "4.0" exactly as stored. The parsed document is still used for structure —
 * codes, references, interpretations — where only the shape matters.
 *
 * The rule from phase 2b, restated: anything reading received_resources that
 * touches a measured value goes through the text path.
 */

export interface IReceivedResource {
  content: FhirResource;
  receivedAt: string | null;
}

/**
 * An Observation plus the numbers that must not pass through a JS double.
 * Null when the Observation carries no quantity — a string or coded result.
 */
export interface IObservation extends IReceivedResource {
  valueText: string | null;
  rangeLowText: string | null;
  rangeHighText: string | null;
}

export class ReceivedModel {
  /**
   * Everything of one type still awaiting processing, oldest first.
   *
   * Oldest first because a laboratory's backlog is a queue: a report that has
   * been waiting twenty minutes for its Observations should be looked at before
   * one that arrived a second ago.
   */
  async unprocessed(resourceType: string): Promise<IReceivedResource[]> {
    const rows = await query<Row>(
      `SELECT content, received_at FROM bridge.received_resources
        WHERE resource_type = $1 AND processed = false
        ORDER BY received_at`,
      [resourceType],
    );
    return rows.map((row) => ({
      content: row.content as FhirResource,
      receivedAt: toIso(row.received_at),
    }));
  }

  async get(resourceType: string, id: string): Promise<IReceivedResource | null> {
    const row = await queryOne<Row>(
      `SELECT content, received_at FROM bridge.received_resources
        WHERE resource_type = $1 AND resource_id = $2`,
      [resourceType, id],
    );
    if (!row) return null;
    return { content: row.content as FhirResource, receivedAt: toIso(row.received_at) };
  }

  /**
   * One Observation, with its quantity and reference range extracted as text.
   *
   * `->>` is doing the load-bearing work: `content -> 'valueQuantity' ->> 'value'`
   * hands back the numeric's own text representation, trailing zeros and all,
   * where reading it off the parsed object would already have lost them.
   */
  async observation(id: string): Promise<IObservation | null> {
    const row = await queryOne<Row>(
      `SELECT content,
              received_at,
              content -> 'valueQuantity' ->> 'value'            AS value_text,
              content -> 'referenceRange' -> 0 -> 'low'  ->> 'value' AS range_low_text,
              content -> 'referenceRange' -> 0 -> 'high' ->> 'value' AS range_high_text
         FROM bridge.received_resources
        WHERE resource_type = 'Observation' AND resource_id = $1`,
      [id],
    );
    if (!row) return null;

    return {
      content: row.content as FhirResource,
      receivedAt: toIso(row.received_at),
      valueText: row.value_text === null || row.value_text === undefined ? null : String(row.value_text),
      rangeLowText:
        row.range_low_text === null || row.range_low_text === undefined ? null : String(row.range_low_text),
      rangeHighText:
        row.range_high_text === null || row.range_high_text === undefined
          ? null
          : String(row.range_high_text),
    };
  }

  async markProcessed(resourceType: string, id: string): Promise<void> {
    await query(
      `UPDATE bridge.received_resources SET processed = true
        WHERE resource_type = $1 AND resource_id = $2`,
      [resourceType, id],
    );
  }
}
