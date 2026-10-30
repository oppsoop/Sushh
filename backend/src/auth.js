import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';
import { env } from './env.js';
import { query } from './db.js';
import { unauthorized } from './errors.js';
import { addDays, addSeconds, randomToken, sha256, uuid } from './util.js';

/* ------------------------------------------------------------------ *
 * Access tokens (JWT, short lived)
 * ------------------------------------------------------------------ */

export function signAccessToken(userId) {
  return jwt.sign({ sub: userId, typ: 'access' }, env.JWT_SECRET, {
    expiresIn: env.ACCESS_TOKEN_TTL,
    issuer: 'worldfriends',
    audience: 'worldfriends-app',
  });
}

export function verifyAccessToken(token) {
  const payload = jwt.verify(token, env.JWT_SECRET, {
    issuer: 'worldfriends',
    audience: 'worldfriends-app',
  });
  if (!payload || payload.typ !== 'access' || !payload.sub) throw unauthorized('invalid_token');
  return payload;
}

/* ------------------------------------------------------------------ *
 * Refresh tokens (opaque, rotated, with reuse detection)
 * ------------------------------------------------------------------ */

export async function issueRefreshToken(userId, { familyId, userAgent } = {}) {
  const token = randomToken(48);
  const id = uuid();
  const family = familyId || uuid();
  await query(
    `insert into refresh_tokens (id, user_id, token_hash, family_id, expires_at, user_agent)
     values ($1, $2, $3, $4, $5, $6)`,
    [id, userId, sha256(token), family, addSeconds(env.REFRESH_TOKEN_TTL), userAgent || null],
  );
  return { token, id, familyId: family, expiresAt: addSeconds(env.REFRESH_TOKEN_TTL) };
}

/**
 * Rotate a refresh token. If a token that was already rotated is presented
 * (i.e. it is being replayed), the whole family is revoked: this is the
 * standard protection against stolen refresh tokens.
 */
export async function rotateRefreshToken(token, userAgent) {
  const hash = sha256(token);
  const { rows } = await query(
    `select id, user_id, family_id, expires_at, revoked_at, replaced_by
       from refresh_tokens where token_hash = $1`,
    [hash],
  );
  const row = rows[0];
  if (!row) throw unauthorized('invalid_refresh_token', 'Session expired, please sign in again.');

  if (row.revoked_at) {
    await query('update refresh_tokens set revoked_at = now() where family_id = $1 and revoked_at is null', [
      row.family_id,
    ]);
    throw unauthorized('refresh_token_reused', 'Session expired, please sign in again.');
  }
  if (new Date(row.expires_at).getTime() < Date.now()) {
    throw unauthorized('refresh_token_expired', 'Session expired, please sign in again.');
  }

  const next = await issueRefreshToken(row.user_id, { familyId: row.family_id, userAgent });
  await query(
    'update refresh_tokens set revoked_at = now(), replaced_by = $2, last_used_at = now() where id = $1',
    [row.id, next.id],
  );
  return { userId: row.user_id, refresh: next };
}

export async function revokeRefreshToken(token) {
  if (!token) return;
  await query('update refresh_tokens set revoked_at = now() where token_hash = $1 and revoked_at is null', [
    sha256(token),
  ]);
}

export async function revokeAllSessions(userId) {
  await query('update refresh_tokens set revoked_at = now() where user_id = $1 and revoked_at is null', [userId]);
}

export async function authPayloadFor(userId, userAgent) {
  const refresh = await issueRefreshToken(userId, { userAgent });
  return {
    accessToken: signAccessToken(userId),
    refreshToken: refresh.token,
    tokenType: 'Bearer',
    expiresIn: env.ACCESS_TOKEN_TTL,
    refreshExpiresAt: refresh.expiresAt.toISOString(),
  };
}

/* ------------------------------------------------------------------ *
 * Express middleware
 * ------------------------------------------------------------------ */

function bearer(req) {
  const header = req.headers.authorization || '';
  if (header.toLowerCase().startsWith('bearer ')) return header.slice(7).trim();
  if (typeof req.query.access_token === 'string') return req.query.access_token;
  return null;
}

export async function requireAuth(req, res, next) {
  try {
    const token = bearer(req);
    if (!token) throw unauthorized();
    const payload = verifyAccessToken(token);
    const { rows } = await query(
      'select id, email, username, display_name, email_verified_at, deleted_at, avatar_media_id, bio from users where id = $1',
      [payload.sub],
    );
    const user = rows[0];
    if (!user) throw unauthorized('unknown_user', 'Account not found');
    if (user.deleted_at) throw unauthorized('account_deleted', 'This account has been deleted.');
    req.user = user;
    req.userId = user.id;
    // Presence is cheap and useful for chat headers; ignore write failures.
    query('update users set last_seen_at = now() where id = $1', [user.id]).catch(() => {});
    return next();
  } catch (err) {
    if (err instanceof jwt.TokenExpiredError) {
      return next(unauthorized('token_expired', 'Access token expired'));
    }
    if (err instanceof jwt.JsonWebTokenError) {
      return next(unauthorized('invalid_token', 'Invalid access token'));
    }
    return next(err);
  }
}

/** Requires a verified email + a claimed username (full app access). */
export function requireOnboarded(req, res, next) {
  if (!req.user?.email_verified_at) {
    return next(unauthorized('email_not_verified', 'Verify your email first.'));
  }
  if (!req.user?.username) {
    return next(new (require('./errors.js').ApiError)(403, 'username_required', 'Choose a username first.'));
  }
  return next();
}

/* ------------------------------------------------------------------ *
 * Google Sign-In (ID token verification, no client library)
 * ------------------------------------------------------------------ */

let googleKeysCache = { fetchedAt: 0, keys: [] };

async function googleKeys() {
  const now = Date.now();
  if (googleKeysCache.keys.length && now - googleKeysCache.fetchedAt < 60 * 60 * 1000) {
    return googleKeysCache.keys;
  }
  const res = await fetch('https://www.googleapis.com/oauth2/v3/certs');
  if (!res.ok) throw new Error(`google certs fetch failed: ${res.status}`);
  const body = await res.json();
  googleKeysCache = { fetchedAt: now, keys: body.keys || [] };
  return googleKeysCache.keys;
}

function b64urlToBuf(s) {
  return Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

/**
 * Verifies a Google ID token: signature against Google's JWKS, issuer,
 * audience, expiry. Returns {sub, email, emailVerified, name, picture}.
 */
export async function verifyGoogleIdToken(idToken, { keysProvider = googleKeys } = {}) {
  const parts = String(idToken || '').split('.');
  if (parts.length !== 3) throw unauthorized('invalid_google_token', 'Malformed Google token');
  const [headerB64, payloadB64, sigB64] = parts;
  const header = JSON.parse(b64urlToBuf(headerB64).toString('utf8'));
  const payload = JSON.parse(b64urlToBuf(payloadB64).toString('utf8'));
  const keys = await keysProvider();
  const jwk = keys.find((k) => k.kid === header.kid) || keys[0];
  if (!jwk) throw unauthorized('invalid_google_token', 'Google signing key unavailable');
  const publicKey = crypto.createPublicKey({ key: jwk, format: 'jwk' });
  const ok = crypto.verify(
    'RSA-SHA256',
    Buffer.from(`${headerB64}.${payloadB64}`),
    publicKey,
    b64urlToBuf(sigB64),
  );
  if (!ok) throw unauthorized('invalid_google_token', 'Google token signature invalid');

  const issuers = ['accounts.google.com', 'https://accounts.google.com'];
  if (!issuers.includes(payload.iss)) throw unauthorized('invalid_google_token', 'Wrong issuer');
  if (!env.GOOGLE_CLIENT_IDS.includes(payload.aud)) {
    throw unauthorized('invalid_google_token', 'Token was not issued for this app');
  }
  if (Number(payload.exp) * 1000 < Date.now()) throw unauthorized('invalid_google_token', 'Google token expired');
  if (!payload.email) throw unauthorized('invalid_google_token', 'Google token has no email');
  return {
    sub: payload.sub,
    email: String(payload.email).toLowerCase(),
    emailVerified: payload.email_verified === true || payload.email_verified === 'true',
    name: payload.name || '',
    picture: payload.picture || '',
  };
}

/* ------------------------------------------------------------------ *
 * Email verification / password reset tokens
 * ------------------------------------------------------------------ */

export async function createEmailToken(userId, purpose, ttlMinutes) {
  const token = randomToken(32);
  await query(
    `insert into email_tokens (id, user_id, token_hash, purpose, expires_at)
     values ($1, $2, $3, $4, $5)`,
    [uuid(), userId, sha256(token), purpose, addSeconds(ttlMinutes * 60)],
  );
  return token;
}

export async function consumeEmailToken(token, purpose) {
  const hash = sha256(String(token || ''));
  const { rows } = await query(
    `select id, user_id, expires_at, used_at from email_tokens
      where token_hash = $1 and purpose = $2`,
    [hash, purpose],
  );
  const row = rows[0];
  if (!row) return null;
  if (row.used_at) return null;
  if (new Date(row.expires_at).getTime() < Date.now()) return null;
  await query('update email_tokens set used_at = now() where id = $1 and used_at is null', [row.id]);
  return { userId: row.user_id };
}

export function verificationUrl(token) {
  return `${env.APP_WEB_URL}/verify-email?token=${encodeURIComponent(token)}`;
}

export function resetUrl(token) {
  return `${env.APP_WEB_URL}/reset-password?token=${encodeURIComponent(token)}`;
}

export const refreshTokenExpiry = () => addDays(env.REFRESH_TOKEN_TTL / 86400);
