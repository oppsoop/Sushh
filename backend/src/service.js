import { query } from './db.js';
import { authPayloadFor } from './auth.js';
import { signedMediaUrl } from './storage.js';
import { env } from './env.js';

export async function getUserById(userId) {
  const { rows } = await query('select * from users where id = $1', [userId]);
  return rows[0] || null;
}

export async function getUserByEmail(email) {
  const { rows } = await query('select * from users where lower(email) = lower($1)', [email]);
  return rows[0] || null;
}

export async function getUserByUsername(username) {
  const { rows } = await query('select * from users where username = $1', [String(username).toLowerCase()]);
  return rows[0] || null;
}

/** The object the app receives about the signed-in user. */
export function selfUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    email: row.email,
    emailVerified: Boolean(row.email_verified_at),
    username: row.username,
    displayName: row.display_name,
    bio: row.bio,
    avatarUrl: row.avatar_media_id ? signedMediaUrl(row.avatar_media_id) : null,
    avatarMediaId: row.avatar_media_id || null,
    profileUrl: row.username ? `https://worldfriends.app/@${row.username}` : null,
    hasUsername: Boolean(row.username),
    needsUsername: Boolean(row.email_verified_at) && !row.username,
    usernameChangeAvailableAt: row.username
      ? new Date(
          new Date(row.username_changed_at || row.created_at).getTime() +
            env.USERNAME_CHANGE_COOLDOWN_DAYS * 24 * 60 * 60 * 1000,
        ).toISOString()
      : null,
    createdAt: row.created_at,
    isBeta: env.BETA_MODE,
  };
}

export function otherUser(row, extra = {}) {
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name || row.username || 'Friend',
    bio: row.bio || '',
    avatarUrl: row.avatar_media_id ? signedMediaUrl(row.avatar_media_id) : null,
    profileUrl: row.username ? `https://worldfriends.app/@${row.username}` : null,
    lastSeenAt: row.last_seen_at || null,
    ...extra,
  };
}

export async function unreadCounts(userId) {
  const { rows } = await query(
    `select m.conversation_id,
            count(*)::int as unread,
            max(m.created_at) as last_at
       from messages m
       join conversation_members cm
         on cm.conversation_id = m.conversation_id and cm.user_id = $1 and cm.left_at is null
      where m.sender_id <> $1
        and m.deleted_at is null
        and not exists (
          select 1 from message_receipts r
           where r.message_id = m.id and r.user_id = $1 and r.read_at is not null
        )
      group by m.conversation_id`,
    [userId],
  );
  const map = {};
  let total = 0;
  for (const row of rows) {
    map[row.conversation_id] = row.unread;
    total += row.unread;
  }
  return { byConversation: map, total };
}

export async function pendingRequestCounts(userId) {
  const { rows } = await query(
    `select
       (select count(*)::int from friend_requests where to_user_id = $1 and status = 'pending') as incoming,
       (select count(*)::int from friend_requests where from_user_id = $1 and status = 'pending') as outgoing,
       (select count(*)::int from notifications where user_id = $1 and read_at is null) as notifications`,
    [userId],
  );
  return rows[0] || { incoming: 0, outgoing: 0, notifications: 0 };
}

/** Everything the app needs on cold start / refresh. */
export async function bootstrap(userId) {
  const user = await getUserById(userId);
  if (!user) return null;
  const [unread, pending, { betaConfig }] = await Promise.all([
    unreadCounts(userId),
    pendingRequestCounts(userId),
    import('./beta.js'),
  ]);
  return {
    user: selfUser(user),
    unread,
    pending,
    beta: await betaConfig(),
    serverTime: new Date().toISOString(),
    features: {
      translation: Boolean(env.DEEPL_API_KEY || env.GOOGLE_TRANSLATE_API_KEY),
      calls: true,
      push: Boolean(env.FCM_PROJECT_ID || env.FCM_SERVICE_ACCOUNT_JSON),
      storage: env.STORAGE,
    },
  };
}

export async function createSession(userId, userAgent) {
  const tokens = await authPayloadFor(userId, userAgent);
  const user = await getUserById(userId);
  return { ...tokens, user: selfUser(user) };
}
