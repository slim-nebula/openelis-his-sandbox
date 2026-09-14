import { query, queryOne, transaction } from '../../../config/db.js';
import { toIso } from '../../../shared/utils/serialization.utils.js';
const toEntry = (row) => ({
    loinc: String(row.loinc),
    openElisTestId: String(row.openelis_test_id),
    name: String(row.name),
    specimenName: String(row.specimen_name),
    specimenId: String(row.specimen_id),
    specimenAbbreviation: row.specimen_abbrev === null || row.specimen_abbrev === undefined
        ? null
        : String(row.specimen_abbrev),
    resultUnit: row.result_unit === null || row.result_unit === undefined ? null : String(row.result_unit),
});
export class CatalogueModel {
    /** Ordered by name, because this is what the doctor's search box renders. */
    async all() {
        const rows = await query(`SELECT loinc, openelis_test_id, name, specimen_name, specimen_id,
              specimen_abbrev, result_unit
         FROM bridge.test_catalogue
        ORDER BY name`);
        return rows.map(toEntry);
    }
    async syncedAt() {
        const row = await queryOne('SELECT max(synced_at) AS synced_at FROM bridge.test_catalogue');
        return toIso(row?.synced_at);
    }
    /**
     * Swaps the whole menu in ONE transaction.
     *
     * Deleting and re-inserting across two statements would leave a window in
     * which the catalogue endpoint returns nothing — and a doctor loading the
     * ordering screen in that window sees an empty list rather than an error,
     * which is the worse of the two failures.
     */
    async replaceAll(entries) {
        await transaction(async (client) => {
            await client.query('DELETE FROM bridge.test_catalogue');
            for (const entry of entries) {
                await client.query(`INSERT INTO bridge.test_catalogue
               (loinc, openelis_test_id, name, specimen_name, specimen_id,
                specimen_abbrev, result_unit, synced_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, now())`, [
                    entry.loinc,
                    entry.openElisTestId,
                    entry.name,
                    entry.specimenName,
                    entry.specimenId,
                    entry.specimenAbbreviation,
                    entry.resultUnit,
                ]);
            }
        });
    }
    async beginSync(testsBefore) {
        const row = await queryOne(`INSERT INTO bridge.catalogue_syncs (status, tests_before)
       VALUES ('RUNNING', $1) RETURNING id`, [testsBefore]);
        return Number(row?.id ?? 0);
    }
    async finishSync(id, status, testsAfter, diff, detail) {
        await query(`UPDATE bridge.catalogue_syncs
          SET finished_at = now(), status = $2, tests_after = $3,
              added = $4, removed = $5, changed = $6, detail = $7
        WHERE id = $1`, [
            id,
            status,
            testsAfter,
            diff.added.join('; '),
            diff.removed.join('; '),
            diff.changed.join('; '),
            detail,
        ]);
    }
    async syncHistory() {
        const rows = await query(`SELECT id, started_at, finished_at, status, tests_before, tests_after,
              added, removed, changed, detail
         FROM bridge.catalogue_syncs
        ORDER BY started_at DESC
        LIMIT 20`);
        return rows.map((row) => ({
            id: Number(row.id),
            startedAt: toIso(row.started_at),
            finishedAt: toIso(row.finished_at),
            status: String(row.status),
            testsBefore: Number(row.tests_before),
            testsAfter: Number(row.tests_after),
            added: row.added === null || row.added === undefined ? null : String(row.added),
            removed: row.removed === null || row.removed === undefined ? null : String(row.removed),
            changed: row.changed === null || row.changed === undefined ? null : String(row.changed),
            detail: row.detail === null || row.detail === undefined ? null : String(row.detail),
        }));
    }
}
