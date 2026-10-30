import { query } from './db.js';
import { deleteObject } from './storage.js';

/**
 * Periodic maintenance. Each function is safe to run repeatedly.
 */

export async function expireStories() {
  const { rows } = await query(
    `select s.id, s.media_id, md.storage_key from stories s
       left join media md on md.id = s.media_id
      where s.expires_at < now() - interval '1 hour'
        and s.deleted_at is null`,
  );
  for (const row of rows) {
    if (row.storage_key) await deleteObject(row.storage_key).catch(() => {});
    if (row.media_id) await query('delete from media where id = $1', [row.media_id]).catch(() => {});
  }
  if (rows.length) {
    await query(`update stories set deleted_at = now() where expires_at < now() - interval '1 hour' and deleted_at is null`);
    await query('delete from stories where deleted_at < now() - interval \'7 days\'');
  }
  return rows.length;
}

/** Hard-deletes accounts that were soft deleted more than 30 days ago. */
export async function purgeDeletedAccounts() {
  const { rows } = await query(
    `select id, email from users where deleted_at is not null and deleted_at < now() - interval '30 days'`,
  );
  for (const user of rows) {
    const { rows: media } = await query('select storage_key from media where owner_id = $1', [user.id]);
    for (const item of media) await deleteObject(item.storage_key).catch(() => {});
    await query('delete from media where owner_id = $1', [user.id]);
    await query('delete from messages where sender_id = $1', [user.id]);
    await query('delete from users where id = $1', [user.id]);
  }
  return rows.length;
}

export async function pruneAnalytics() {
  const { rowCount } = await query(`delete from analytics_events where created_at < now() - interval '180 days'`);
  await query(`delete from push_log where created_at < now() - interval '30 days'`);
  await query(`delete from notifications where read_at is not null and created_at < now() - interval '90 days'`);
  return rowCount || 0;
}

export function startJobs() {
  const run = async () => {
    try {
      await expireStories();
      await purgeDeletedAccounts();
      await pruneAnalytics();
    } catch (err) {
      console.error('[jobs] error', err.message);
    }
  };
  run();
  const timer = setInterval(run, 60 * 60 * 1000);
  timer.unref?.();
  return () => clearInterval(timer);
}
