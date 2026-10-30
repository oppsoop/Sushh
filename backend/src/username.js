import { env } from './env.js';
import { query, withTransaction } from './db.js';
import { ApiError, badRequest, conflict } from './errors.js';
import { addDays } from './util.js';

export const USERNAME_MIN = 3;
export const USERNAME_MAX = 20;
export const USERNAME_PATTERN = /^[a-z][a-z0-9._]*$/;

/** Names that can never be claimed, in any casing or obfuscation. */
export const RESERVED_USERNAMES = new Set([
  'admin', 'administrator', 'support', 'help', 'moderator', 'owner', 'root', 'system',
  'official', 'team', 'security', 'api', 'null', 'undefined',
  // Extra impersonation-prone names the owner should never lose control of.
  'worldfriends', 'worldfriend', 'staff', 'mod', 'mods', 'billing', 'abuse', 'legal',
  'privacy', 'tos', 'contact', 'noreply', 'no-reply', 'webmaster', 'postmaster',
  'developer', 'developers',
]);

/**
 * Offensive / impersonation blocks. Matching is done on the "core" of the
 * username (digits, dots and underscores stripped, common leet letters folded)
 * so that `h3lp_me` or `s.u.p.p.o.r.t` cannot slip through.
 */
export const BLOCKED_TERMS = [
  'fuck', 'fuk', 'fck', 'shit', 'bitch', 'bastard', 'asshole', 'dick', 'cunt', 'slut',
  'whore', 'pussy', 'nigg', 'niger', 'fag', 'retard', 'rape', 'pedo', 'paedo',
  'molest', 'incest', 'hentai', 'porn', 'nazi', 'hitler', 'kkk', 'terrorist',
  'killer', 'murder', 'scam', 'phish', 'hacker', 'crack', 'pirate', 'spam',
  'viagra', 'casino', 'betting', 'loan', 'crypto', 'onlyfans', 'sex', 'xxx',
];

const LEET_MAP = {
  0: 'o', 1: 'i', 3: 'e', 4: 'a', 5: 's', 7: 't', 8: 'b', 9: 'g',
  '@': 'a', $: 's', '!': 'i', '|': 'i',
};

function core(username) {
  let out = '';
  for (const ch of username.toLowerCase()) {
    if (LEET_MAP[ch]) out += LEET_MAP[ch];
    else if (/[a-z]/.test(ch)) out += ch;
    // dots, underscores, numbers already folded above; everything else dropped
  }
  return out;
}

/** Returns {ok:true} or {ok:false, code, message}. */
export function validateUsername(raw) {
  if (typeof raw !== 'string') {
    return { ok: false, code: 'invalid', message: 'Username is required.' };
  }
  const username = raw.trim().toLowerCase();
  if (username !== raw.trim()) {
    // Uppercase input is normalized rather than rejected, but callers should
    // show the normalized value back to the user.
  }
  if (username.length < USERNAME_MIN) {
    return { ok: false, code: 'too_short', message: `Username must be at least ${USERNAME_MIN} characters.` };
  }
  if (username.length > USERNAME_MAX) {
    return { ok: false, code: 'too_long', message: `Username must be at most ${USERNAME_MAX} characters.` };
  }
  if (!/^[a-z]/.test(username)) {
    return { ok: false, code: 'must_start_with_letter', message: 'Username must start with a letter.' };
  }
  if (!USERNAME_PATTERN.test(username)) {
    return {
      ok: false,
      code: 'invalid_characters',
      message: 'Use lowercase letters, numbers, underscores and periods only.',
    };
  }
  if (username.includes('..')) {
    return { ok: false, code: 'consecutive_periods', message: 'Username cannot contain two periods in a row.' };
  }
  if (username.endsWith('.')) {
    return { ok: false, code: 'trailing_period', message: 'Username cannot end with a period.' };
  }
  if (RESERVED_USERNAMES.has(username)) {
    return { ok: false, code: 'reserved', message: 'That username is reserved.' };
  }
  const normalized = core(username);
  if (RESERVED_USERNAMES.has(normalized)) {
    return { ok: false, code: 'reserved', message: 'That username is reserved.' };
  }
  const segments = username.split(/[._]+/).filter(Boolean);
  for (const segment of segments) {
    if (RESERVED_USERNAMES.has(segment)) {
      return { ok: false, code: 'reserved', message: 'That username is reserved.' };
    }
  }
  for (const term of BLOCKED_TERMS) {
    // Match at a word edge (or anywhere for long terms) so legitimate names such
    // as "grape" are not rejected just because they contain "rape".
    const atEdge = normalized === term || normalized.startsWith(term) || normalized.endsWith(term);
    const embedded = term.length >= 5 && normalized.includes(term);
    if (atEdge || embedded) {
      return { ok: false, code: 'offensive', message: 'That username is not allowed.' };
    }
  }
  return { ok: true, username };
}

/** Suggestions offered when a username is taken. */
export function suggestionsFor(username) {
  const year = new Date().getFullYear();
  const list = [
    `${username}${Math.floor(Math.random() * 90) + 10}`,
    `${username}_`,
    `${username}.`,
    `the${username}`,
    `${username}${String(year).slice(-2)}`,
  ]
    .map((s) => s.slice(0, USERNAME_MAX))
    .filter((s) => validateUsername(s).ok);
  return [...new Set(list)].slice(0, 3);
}

/** True when `username` was released less than the cool-down window ago. */
async function releasedRecently(client, username, excludeUserId) {
  const db = client || { query };
  const cutoff = addDays(-env.USERNAME_REUSE_COOLDOWN_DAYS);
  const { rows } = await db.query(
    `select 1 from username_history
      where username = $1 and released_at > $2 and ($3::uuid is null or user_id <> $3)
      limit 1`,
    [username, cutoff, excludeUserId || null],
  );
  return rows.length > 0;
}

async function takenByOther(client, username, userId) {
  const db = client || { query };
  const { rows } = await db.query(
    'select id from users where username = $1 and id <> $2 limit 1',
    [username, userId || '00000000-0000-0000-0000-000000000000'],
  );
  return rows.length > 0;
}

/**
 * Live availability check used while the user types and again on submit.
 * Returns availability plus actionable suggestions.
 */
export async function checkAvailability(raw, currentUserId) {
  const validated = validateUsername(raw);
  const normalized = String(raw || '').trim().toLowerCase();
  if (!validated.ok) {
    return {
      username: normalized,
      available: false,
      reason: validated.code,
      message: validated.message,
      suggestions: [],
    };
  }
  const username = validated.username;
  if (currentUserId) {
    const { rows } = await query('select username from users where id = $1', [currentUserId]);
    if (rows[0]?.username === username) {
      return { username, available: true, reason: 'already_yours', message: 'This is your current username.', suggestions: [] };
    }
  }
  if (await takenByOther(null, username, currentUserId)) {
    return {
      username,
      available: false,
      reason: 'taken',
      message: 'That username is already taken.',
      suggestions: suggestionsFor(username),
    };
  }
  if (await releasedRecently(null, username, currentUserId)) {
    return {
      username,
      available: false,
      reason: 'recently_released',
      message: `That username was used recently and cannot be reused for ${env.USERNAME_REUSE_COOLDOWN_DAYS} days.`,
      suggestions: suggestionsFor(username),
    };
  }
  return { username, available: true, reason: 'ok', message: 'Available', suggestions: [] };
}

/**
 * Atomically claim a username for a user.
 *
 * Serialization: a transaction-scoped advisory lock on the username hash makes
 * two simultaneous claims for the same name queue up, and the unique index on
 * users.username is the final backstop (defence in depth - if the advisory lock
 * is ever bypassed the insert still fails with 23505).
 */
export async function claimUsername(userId, raw, { changing = false } = {}) {
  const validated = validateUsername(raw);
  if (!validated.ok) throw new ApiError(400, validated.code, validated.message);
  const username = validated.username;

  return withTransaction(async (client) => {
    await client.query('select pg_advisory_xact_lock(hashtext($1))', [`username:${username}`]);

    const { rows: meRows } = await client.query(
      'select id, username, username_changed_at, email_verified_at from users where id = $1 for update',
      [userId],
    );
    const me = meRows[0];
    if (!me) throw new ApiError(401, 'unknown_user', 'Account not found');
    if (!me.email_verified_at) {
      throw new ApiError(403, 'email_not_verified', 'Verify your email before choosing a username.');
    }
    if (me.username === username) {
      return { username, changed: false, suggestions: [] };
    }
    if (!changing && me.username) {
      throw conflict('username_already_set', 'You already have a username.');
    }
    if (changing) {
      const cooldownMs = env.USERNAME_CHANGE_COOLDOWN_DAYS * 24 * 60 * 60 * 1000;
      const last = me.username_changed_at ? new Date(me.username_changed_at).getTime() : 0;
      const next = last + cooldownMs;
      if (last && Date.now() < next) {
        throw new ApiError(429, 'username_change_cooldown', 'You can only change your username once every 30 days.', {
          nextChangeAt: new Date(next).toISOString(),
        });
      }
    }

    if (await takenByOther(client, username, userId)) {
      throw conflict('username_taken', 'That username is already taken.', { suggestions: suggestionsFor(username) });
    }
    if (await releasedRecently(client, username, userId)) {
      throw conflict('username_recently_released', 'That username was used recently and is still reserved.', {
        suggestions: suggestionsFor(username),
      });
    }

    if (me.username) {
      await client.query(
        'insert into username_history (username, user_id, released_at) values ($1, $2, now())',
        [me.username, userId],
      );
    }

    try {
      await client.query(
        'update users set username = $2, username_changed_at = now(), updated_at = now() where id = $1',
        [userId, username],
      );
    } catch (err) {
      if (err.code === '23505') {
        // Another transaction won the race.
        throw conflict('username_taken', 'That username is already taken.', { suggestions: suggestionsFor(username) });
      }
      throw err;
    }
    return { username, previous: me.username || null, changed: Boolean(me.username), suggestions: [] };
  });
}
