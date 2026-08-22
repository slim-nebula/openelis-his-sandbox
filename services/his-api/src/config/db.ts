import pg from 'pg';
import { config } from './env.js';
import { logger } from './logger.js';

/**
 * Postgres access for the whole service.
 *
 * WHY NOT PRISMA, WHEN THE REST OF THE ESTATE USES IT
 *
 * Prisma is right where a service OWNS its schema — patient-service defines its
 * tables in schema.prisma and migrates them with Prisma Migrate, so the client
 * and the database cannot drift.
 *
 * This service does not own its schema. `db/his/*.sql` does, applied by
 * `scripts/migrate.sh`, which is the same runner the bridge's database uses.
 * Introducing Prisma here would mean a schema.prisma that has to be kept in
 * step with SQL it does not control — drift with extra steps.
 *
 * The hot paths would be raw anyway. The outbox relay claims rows with
 * FOR UPDATE SKIP LOCKED; the status update uses IS DISTINCT FROM so that a
 * repeated status writes no audit row; the catalogue mirror upserts with a
 * WHERE clause on the EXISTING row. Prisma expresses all three only through
 * $queryRaw, so it would be a Prisma-shaped wrapper around the same SQL.
 *
 * A new HIS service that owns its tables should use Prisma, as yours do.
 */
export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on('error', (err) => {
  // An idle client erroring is not tied to any request, so it surfaces here or
  // nowhere. Left unhandled, node treats it as an uncaught exception.
  logger.error(`Idle postgres client error: ${err.message}`);
});

export type Row = Record<string, unknown>;

export const query = async <T extends Row>(text: string, params: unknown[] = []): Promise<T[]> => {
  const result = await pool.query(text, params);
  return result.rows as T[];
};

/** First row, or null. The shape most reads here actually want. */
export const queryOne = async <T extends Row>(text: string, params: unknown[] = []): Promise<T | null> => {
  const rows = await query<T>(text, params);
  return rows[0] ?? null;
};

/**
 * Runs `fn` inside a transaction, rolling back on any throw.
 *
 * Order creation depends on this: the order row, its audit row and its outbox
 * event commit together or not at all. That single commit is what makes a crash
 * between "order saved" and "event published" impossible.
 */
export const transaction = async <T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
};

export const waitForDatabase = async (attempts = 60): Promise<void> => {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await pool.query('SELECT 1');
      logger.info(`HIS database reachable after ${attempt} attempt(s)`);
      return;
    } catch (error) {
      if (attempt === attempts) throw error;
      logger.warn(`HIS database not ready (${(error as Error).message}); retrying in 2s`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
};
