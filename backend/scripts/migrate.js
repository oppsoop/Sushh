import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool } from '../src/db.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.resolve(here, '../migrations');

export async function migrate({ quiet = false } = {}) {
  const client = await pool.connect();
  const applied = [];
  try {
    await client.query('begin');
    await client.query(`create table if not exists schema_migrations (version text primary key, applied_at timestamptz not null default now())`);
    const files = (await fs.readdir(migrationsDir)).filter((f) => f.endsWith('.sql')).sort();
    for (const file of files) {
      const { rows } = await client.query('select 1 from schema_migrations where version = $1', [file]);
      if (rows.length) continue;
      const sql = await fs.readFile(path.join(migrationsDir, file), 'utf8');
      await client.query(sql);
      await client.query('insert into schema_migrations (version) values ($1)', [file]);
      applied.push(file);
      if (!quiet) console.log(`[migrate] applied ${file}`);
    }
    await client.query('commit');
  } catch (err) {
    await client.query('rollback').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
  if (!quiet) console.log(applied.length ? `[migrate] ${applied.length} migration(s) applied` : '[migrate] up to date');
  return applied;
}

if (process.argv[1] && process.argv[1].endsWith('migrate.js')) {
  migrate()
    .then(() => pool.end())
    .catch((err) => {
      console.error('[migrate] failed', err);
      process.exit(1);
    });
}
