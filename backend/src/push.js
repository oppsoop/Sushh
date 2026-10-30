import crypto from 'node:crypto';
import fs from 'node:fs';
import { env } from './env.js';
import { query } from './db.js';

/* ------------------------------------------------------------------ *
 * Firebase Cloud Messaging HTTP v1
 *
 * Implemented with node:crypto so no Google SDK is required. Works with a
 * service account JSON (inline env var, file path, or split FCM_* vars).
 * When no credentials are configured every call is a logged no-op so local
 * development and CI keep working.
 * ------------------------------------------------------------------ */

let cachedCredentials = null;
let cachedToken = { value: null, expiresAt: 0 };

function loadCredentials() {
  if (cachedCredentials !== null) return cachedCredentials;
  const candidates = [];
  if (env.FCM_SERVICE_ACCOUNT_JSON) candidates.push(env.FCM_SERVICE_ACCOUNT_JSON);
  if (process.env.FCM_SERVICE_ACCOUNT_FILE) candidates.push(process.env.FCM_SERVICE_ACCOUNT_FILE);
  candidates.push('/secrets/firebase-service-account.json');

  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      const raw = candidate.trim().startsWith('{') ? candidate : fs.readFileSync(candidate, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed.project_id && parsed.client_email && parsed.private_key) {
        cachedCredentials = {
          projectId: parsed.project_id,
          clientEmail: parsed.client_email,
          privateKey: parsed.private_key.replace(/\\n/g, '\n'),
        };
        return cachedCredentials;
      }
    } catch {
      /* try next candidate */
    }
  }
  if (env.FCM_PROJECT_ID && env.FCM_CLIENT_EMAIL && env.FCM_PRIVATE_KEY) {
    cachedCredentials = {
      projectId: env.FCM_PROJECT_ID,
      clientEmail: env.FCM_CLIENT_EMAIL,
      privateKey: env.FCM_PRIVATE_KEY,
    };
    return cachedCredentials;
  }
  cachedCredentials = false;
  return false;
}

export function pushConfigured() {
  return Boolean(loadCredentials());
}

function base64url(input) {
  return Buffer.from(input).toString('base64url');
}

async function accessToken() {
  const creds = loadCredentials();
  if (!creds) throw new Error('push_not_configured');
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken.value && cachedToken.expiresAt - 60 > now) return cachedToken.value;

  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64url(
    JSON.stringify({
      iss: creds.clientEmail,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(`${header}.${claims}`);
  const signature = signer.sign(creds.privateKey).toString('base64url');
  const assertion = `${header}.${claims}.${signature}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`fcm oauth failed: ${res.status} ${text.slice(0, 200)}`);
  }
  const body = await res.json();
  cachedToken = { value: body.access_token, expiresAt: now + (body.expires_in || 3600) };
  return cachedToken.value;
}

async function sendOne(device, message) {
  const creds = loadCredentials();
  const token = await accessToken();
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${creds.projectId}/messages:send`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ message: { token: device.fcm_token, ...message } }),
  });
  if (res.ok) return { ok: true };
  const text = await res.text();
  const invalid = res.status === 404 || text.includes('UNREGISTERED') || text.includes('INVALID_ARGUMENT');
  return { ok: false, error: `${res.status} ${text.slice(0, 300)}`, invalid };
}

/**
 * Send a notification to every device of a user.
 * `data` values must be strings (FCM requirement).
 */
export async function sendPushToUser(userId, { title, body, data = {}, channelId = 'default', highPriority = false }) {
  if (!pushConfigured()) {
    console.log(`[push] skipped (not configured) user=${userId} title="${title}"`);
    return { sent: 0, skipped: true };
  }
  const { rows: devices } = await query(
    'select id, fcm_token from devices where user_id = $1',
    [userId],
  );
  if (!devices.length) return { sent: 0, skipped: true };

  const stringData = Object.fromEntries(
    Object.entries(data).map(([k, v]) => [k, v === null || v === undefined ? '' : String(v)]),
  );
  const message = {
    notification: { title, body },
    data: stringData,
    android: {
      priority: highPriority ? 'high' : 'normal',
      notification: {
        channel_id: channelId,
        sound: 'default',
        // Call/chat taps must open the right screen without duplicating entries.
        tag: stringData.tag || undefined,
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
      },
    },
  };

  let sent = 0;
  for (const device of devices) {
    try {
      const result = await sendOne(device, message);
      if (result.ok) sent += 1;
      if (!result.ok && result.invalid) {
        await query('delete from devices where id = $1', [device.id]);
      }
      await query('insert into push_log (user_id, device_id, title, body, ok, error) values ($1,$2,$3,$4,$5,$6)', [
        userId,
        device.id,
        title,
        body,
        Boolean(result.ok),
        result.ok ? null : result.error,
      ]);
    } catch (err) {
      console.error('[push] send failed', err.message);
      await query('insert into push_log (user_id, device_id, title, body, ok, error) values ($1,$2,$3,$4,$5,$6)', [
        userId,
        device.id,
        title,
        body,
        false,
        err.message,
      ]).catch(() => {});
    }
  }
  return { sentiment: undefined, sent, skipped: false };
}
