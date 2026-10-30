import crypto from 'node:crypto';

export const uuid = () => crypto.randomUUID();

export const nowIso = () => new Date().toISOString();

export function addDays(days, from = new Date()) {
  return new Date(from.getTime() + days * 24 * 60 * 60 * 1000);
}

export function addSeconds(seconds, from = new Date()) {
  return new Date(from.getTime() + seconds * 1000);
}

/* ------------------------------------------------------------------ *
 * Password hashing (scrypt, no native dependency)
 * ------------------------------------------------------------------ */

const SCRYPT_N = 16384;
const SCRYPT_r = 8;
const SCRYPT_p = 1;
const KEYLEN = 64;

export function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16);
    crypto.scrypt(password, salt, KEYLEN, { N: SCRYPT_N, r: SCRYPT_r, p: SCRYPT_p }, (err, key) => {
      if (err) return reject(err);
      resolve(`scrypt$${SCRYPT_N}$${SCRYPT_r}$${SCRYPT_p}$${salt.toString('base64')}$${key.toString('base64')}`);
    });
  });
}

export function verifyPassword(password, stored) {
  return new Promise((resolve) => {
    if (!stored || typeof stored !== 'string') return resolve(false);
    const parts = stored.split('$');
    if (parts.length !== 6 || parts[0] !== 'scrypt') return resolve(false);
    const [, N, r, p, saltB64, hashB64] = parts;
    const salt = Buffer.from(saltB64, 'base64');
    const expected = Buffer.from(hashB64, 'base64');
    crypto.scrypt(
      password,
      salt,
      expected.length,
      { N: Number(N), r: Number(r), p: Number(p) },
      (err, key) => {
        if (err) return resolve(false);
        resolve(key.length === expected.length && crypto.timingSafeEqual(key, expected));
      },
    );
  });
}

/* ------------------------------------------------------------------ *
 * Opaque tokens
 * ------------------------------------------------------------------ */

export const randomToken = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');
export const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');
export const randomCode = (length = 6) => {
  const digits = '0123456789';
  let out = '';
  const bytes = crypto.randomBytes(length);
  for (let i = 0; i < length; i += 1) out += digits[bytes[i] % 10];
  return out;
};

/* ------------------------------------------------------------------ *
 * HMAC signed media URLs
 * ------------------------------------------------------------------ */

export function hmac(secret, payload) {
  return crypto.createHmac('sha256', secret).update(payload).digest('base64url');
}

export function safeEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

/* ------------------------------------------------------------------ *
 * Cursor pagination helpers.
 * Cursors encode (sortKey, id) so pages stay stable when rows are added.
 * ------------------------------------------------------------------ */

export function encodeCursor(createdAt, id) {
  const iso = createdAt instanceof Date ? createdAt.toISOString() : createdAt;
  return Buffer.from(JSON.stringify([iso, id]), 'utf8').toString('base64url');
}

export function decodeCursor(cursor) {
  if (!cursor) return null;
  try {
    const parsed = JSON.parse(Buffer.from(String(cursor), 'base64url').toString('utf8'));
    if (!Array.isArray(parsed) || parsed.length !== 2) return null;
    const [createdAt, id] = parsed;
    const date = new Date(createdAt);
    if (Number.isNaN(date.getTime()) || typeof id !== 'string') return null;
    return { createdAt: date, id };
  } catch {
    return null;
  }
}

export function encodeValues(values) {
  return Buffer.from(JSON.stringify(values), 'utf8').toString('base64url');
}

export function decodeValues(cursor, arity) {
  if (!cursor) return null;
  try {
    const parsed = JSON.parse(Buffer.from(String(cursor), 'base64url').toString('utf8'));
    if (!Array.isArray(parsed) || parsed.length !== arity) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function pageLimit(value, def = 25, max = 100) {
  const n = Number.parseInt(value, 10);
  if (!Number.isFinite(n) || n <= 0) return def;
  return Math.min(n, max);
}

/* ------------------------------------------------------------------ *
 * Misc
 * ------------------------------------------------------------------ */

export function publicUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name ?? row.displayName ?? '',
    bio: row.bio ?? '',
    avatarMediaId: row.avatar_media_id ?? null,
    avatarUrl: row.avatar_media_id ? `/v1/media/${row.avatar_media_id}` : null,
    email: row.email,
    emailVerified: Boolean(row.email_verified_at),
    profileUrl: row.username ? `https://worldfriends.app/@${row.username}` : null,
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at ?? null,
    deleted: Boolean(row.deleted_at),
  };
}

export function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

export function isEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(email || '').trim());
}

export function parseIntOr(value, def) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : def;
}
