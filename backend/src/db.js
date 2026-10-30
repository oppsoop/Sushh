import pg from 'pg';
import { env } from './env.js';

// node-postgres returns bigint (int8) as string; media byte sizes are small
// enough that a Number is safe and much easier on the API surface.
pg.types.setTypeParser(20, (v) => (v === null ? null : Number(v)));

export const pool = new pg.Pool({
  connectionString: env.DATABASE_URL,
  ssl: env.DATABASE_SSL ? {
    rejectUnauthorized: env.DATABASE_SSL_VERIFY,
    ...(env.DATABASE_CA_CERT ? { ca: env.DATABASE_CA_CERT } : {}),
  } : false,
  max: Number(process.env.PG_POOL_MAX || 10),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

pool.on('error', (err) => {
  console.error('[db] idle client error', err.message);
});

export function query(text, params) {
  return pool.query(text, params);
}

/** Run `fn` inside a transaction with a dedicated client. */
export async function withTransaction(fn, isolationLevel) {
  const client = await pool.connect();
  try {
    if (isolationLevel) await client.query(`begin isolation level ${isolationLevel}`);
    else await client.query('begin');
    const result = await fn(client);
    await client.query('commit');
    return result;
  } catch (err) {
    try {
      await client.query('rollback');
    } catch {
      /* connection already broken */
    }
    throw err;
  } finally {
    client.release();
  }
}

/** Only used by tests. */
export async function closePool() {
  await pool.end();
}
