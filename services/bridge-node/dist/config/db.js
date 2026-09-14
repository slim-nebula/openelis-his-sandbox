import pg from 'pg';
import { config } from './env.js';
import { logger } from './logger.js';
/**
 * Postgres access for the whole service.
 *
 * WHY NOT PRISMA, WHEN THE REST OF THE ESTATE USES IT
 *
 * The same answer his-api gives, and it holds more strongly here. This service
 * does not own its schema — `db/bridge/*.sql` does, applied by
 * `scripts/migrate.sh` — so a schema.prisma would have to be kept in step with
 * SQL it does not control.
 *
 * And the bridge's tables are not entity-shaped. They are a jsonb document
 * store, a claim table and a lease table, queried by set operations Prisma
 * cannot express: the delivery lease reads and claims in ONE statement with a
 * CTE and `ON CONFLICT ... WHERE`, the Task search filters on jsonb paths, and
 * the reconciliation ledger counts with FILTER aggregates. Roughly seven
 * queries in ten would be $queryRaw, which is a Prisma-shaped wrapper around
 * the same SQL plus a second source of truth for the schema.
 *
 * A new HIS service that owns its tables should use Prisma, as yours do.
 *
 * ONE TRAP WORTH KNOWING, because it has already been paid for twice in the
 * .NET version: node-postgres returns `bigint` as a STRING (to avoid silent
 * precision loss) and `numeric` as a string too. So `count(*)` and
 * `extract(epoch ...)` do not arrive as numbers. Every such query here casts in
 * SQL — `::int`, `::double precision` — and the callers coerce as well. A gauge
 * fed a string publishes NaN, which reads as a missing metric rather than a
 * wrong one.
 */
export const pool = new pg.Pool({
    // Discrete fields or a connection string, depending on which shape
    // BRIDGE_DB_CONNECTION held — see databaseConnection() in env.ts.
    ...config.database,
    max: 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
});
pool.on('error', (err) => {
    // An idle client erroring is not tied to any request, so it surfaces here or
    // nowhere. Left unhandled, node treats it as an uncaught exception.
    logger.error(`Idle postgres client error: ${err.message}`);
});
export const query = async (text, params = []) => {
    const result = await pool.query(text, params);
    return result.rows;
};
/** First row, or null. The shape most reads here actually want. */
export const queryOne = async (text, params = []) => {
    const rows = await query(text, params);
    return rows[0] ?? null;
};
/**
 * Runs `fn` inside a transaction, rolling back on any throw.
 *
 * Publishing an order depends on this: the Patient, Organization, Practitioner,
 * Specimen, ServiceRequest and Task rows, plus the tracking row, all commit
 * together. A half-written order is one OpenELIS could poll and fail to
 * dereference.
 */
export const transaction = async (fn) => {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const result = await fn(client);
        await client.query('COMMIT');
        return result;
    }
    catch (error) {
        await client.query('ROLLBACK');
        throw error;
    }
    finally {
        client.release();
    }
};
export const waitForDatabase = async (attempts = 60) => {
    for (let attempt = 1; attempt <= attempts; attempt++) {
        try {
            await pool.query('SELECT 1');
            logger.info(`Bridge database reachable after ${attempt} attempt(s)`);
            return;
        }
        catch (error) {
            if (attempt === attempts)
                throw error;
            logger.warn(`Bridge database not ready (${error.message}); retrying in 2s`);
            await new Promise((resolve) => setTimeout(resolve, 2000));
        }
    }
};
