import { query, withTransaction } from './db.js';
import { uuid } from './util.js';

export function pair(a, b) {
  return a < b ? [a, b] : [b, a];
}

export async function areFriends(a, b) {
  if (!a || !b || a === b) return false;
  const [x, y] = pair(a, b);
  const { rows } = await query('select 1 from friendships where user_a = $1 and user_b = $2', [x, y]);
  return rows.length > 0;
}

export async function blockedEither(a, b) {
  if (!a || !b) return false;
  const { rows } = await query(
    `select 1 from blocks
      where (blocker_id = $1 and blocked_id = $2) or (blocker_id = $2 and blocked_id = $1) limit 1`,
    [a, b],
  );
  return rows.length > 0;
}

export async function createFriendship(a, b) {
  const [x, y] = pair(a, b);
  await query(
    `insert into friendships (user_a, user_b) values ($1, $2) on conflict do nothing`,
    [x, y],
  );
  // Friends automatically follow each other.
  await query('insert into follows (follower_id, following_id) values ($1, $2) on conflict do nothing', [a, b]);
  await query('insert into follows (follower_id, following_id) values ($1, $2) on conflict do nothing', [b, a]);
}

export async function removeFriendship(a, b) {
  const [x, y] = pair(a, b);
  await query('delete from friendships where user_a = $1 and user_b = $2', [x, y]);
}

export async function friendIds(userId) {
  const { rows } = await query(
    `select case when user_a = $1 then user_b else user_a end as id
       from friendships where user_a = $1 or user_b = $1`,
    [userId],
  );
  return rows.map((r) => r.id);
}

/** One direct conversation per pair, created lazily and race-free. */
export async function ensureDirectConversation(a, b) {
  const pairKey = pair(a, b).join(':');
  const existing = await query('select id from conversations where pair_key = $1', [pairKey]);
  if (existing.rows[0]) return existing.rows[0].id;
  return withTransaction(async (client) => {
    const id = uuid();
    const inserted = await client.query(
      `insert into conversations (id, kind, pair_key, created_by, created_at, last_message_at)
       values ($1, 'direct', $2, $3, now(), now())
       on conflict (pair_key) do nothing
       returning id`,
      [id, pairKey, a],
    );
    const conversationId = inserted.rows[0]?.id;
    if (!conversationId) {
      const again = await client.query('select id from conversations where pair_key = $1', [pairKey]);
      return again.rows[0].id;
    }
    await client.query(
      `insert into conversation_members (conversation_id, user_id) values ($1, $2), ($1, $3)
       on conflict do nothing`,
      [conversationId, a, b],
    );
    return conversationId;
  });
}
