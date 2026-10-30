import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocket } from 'ws';

// Environment must be configured before the app modules are imported.
process.env.NODE_ENV = 'test';
process.env.JWT_SECRET = 'test-secret-test-secret-test-secret-1234';
process.env.RATE_LIMIT_DISABLED = 'true';
process.env.ALLOW_DEV_CODES = 'true';
process.env.BETA_MODE = 'true';
process.env.BETA_ALLOW_ANY_EMAIL = 'false';
process.env.BETA_ALLOWED_EMAILS = 'vip@example.com';
process.env.BETA_INVITE_CODES = 'FRIENDS2026';
process.env.STORAGE = 'local';
process.env.MEDIA_DIR = `/tmp/wf-test-media-${process.pid}`;
process.env.ACCESS_TOKEN_TTL_SECONDS = '900';
process.env.TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL || 'postgresql://postgres:@/worldfriends_test?host=/tmp/pgdata';
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL;

let pool;

export async function resetDatabase() {
  const { pool: dbPool } = await import('../src/db.js');
  pool = dbPool;
  await pool.query('drop schema public cascade');
  await pool.query('create schema public');
  const { migrate } = await import('../scripts/migrate.js');
  await migrate({ quiet: true });
}

export async function startTestServer() {
  const { createApp } = await import('../src/app.js');
  const { initRealtime } = await import('../src/realtime.js');
  const app = createApp();
  const server = http.createServer(app);
  initRealtime(server);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  const baseUrl = `http://127.0.0.1:${port}`;

  return {
    baseUrl,
    port,
    async close() {
      const { closeRealtime } = await import('../src/realtime.js');
      await closeRealtime();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

export async function request(baseUrl, path, { method = 'GET', body, token, headers = {}, form } = {}) {
  const init = { method, headers: { ...headers } };
  if (token) init.headers.authorization = `Bearer ${token}`;
  if (form) {
    init.body = form;
  } else if (body !== undefined) {
    init.headers['content-type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const res = await fetch(`${baseUrl}${path}`, init);
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, body: json, headers: res.headers };
}

let counter = 0;
export function uniqueEmail(prefix = 'user') {
  counter += 1;
  return `${prefix}${Date.now().toString(36)}${counter}@example.com`;
}

/**
 * Full signup: register -> verify email -> claim username.
 * Returns everything a test needs to act as that user.
 */
export async function createUser(baseUrl, { email, password = 'Passw0rd!23', username, displayName = 'Test User', inviteCode = 'FRIENDS2026' } = {}) {
  const mail = email || uniqueEmail();
  const reg = await request(baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: { email: mail, password, displayName, inviteCode },
  });
  if (reg.status !== 201) throw new Error(`register failed: ${reg.status} ${JSON.stringify(reg.body)}`);
  const code = reg.body.devCode;
  if (!code) throw new Error('no dev code, ALLOW_DEV_CODES must be on');

  const verified = await request(baseUrl, '/v1/auth/verify-email', {
    method: 'POST',
    body: { email: mail, code },
  });
  if (verified.status !== 200) throw new Error(`verify failed: ${verified.status} ${JSON.stringify(verified.body)}`);

  let token = verified.body.accessToken;
  let refreshToken = verified.body.refreshToken;
  const alphabet = 'bcdfghjkmnpqrstvwxyz';
  const suffix = Array.from({ length: 8 }, () => alphabet[crypto.randomInt(alphabet.length)]).join('');
  const handle = username || `u${suffix}`;
  const claimed = await request(baseUrl, '/v1/username/claim', {
    method: 'POST',
    body: { username: handle },
    token,
  });
  if (claimed.status !== 201) throw new Error(`claim failed: ${claimed.status} ${JSON.stringify(claimed.body)}`);

  return {
    id: verified.body.user.id,
    email: mail,
    password,
    username: handle,
    token,
    refreshToken,
    user: claimed.body.user,
  };
}

/**
 * Register + verify email without claiming a username, so tests can exercise
 * the username screen exactly like a real new user.
 */
export async function createUnclaimedUser(baseUrl, { email, password = 'Passw0rd!23', displayName = 'New User' } = {}) {
  const mail = email || uniqueEmail('fresh');
  const reg = await request(baseUrl, '/v1/auth/register', {
    method: 'POST',
    body: { email: mail, password, displayName, inviteCode: 'FRIENDS2026' },
  });
  if (reg.status !== 201) throw new Error(`register failed: ${reg.status} ${JSON.stringify(reg.body)}`);
  const verified = await request(baseUrl, '/v1/auth/verify-email', {
    method: 'POST',
    body: { email: mail, code: reg.body.devCode },
  });
  if (verified.status !== 200) throw new Error(`verify failed: ${verified.status}`);
  return {
    id: verified.body.user.id,
    email: mail,
    password,
    token: verified.body.accessToken,
    refreshToken: verified.body.refreshToken,
    usernameIdeas: verified.body.usernameIdeas,
  };
}

export function api(baseUrl, token) {
  return (path, options = {}) => request(baseUrl, path, { ...options, token: options.token ?? token });
}

/** Connect a socket and wait for the 'ready' frame. */
export function openSocket(baseUrl, token) {
  const wsUrl = baseUrl.replace('http', 'ws');
  const socket = new WebSocket(`${wsUrl}/ws?token=${encodeURIComponent(token)}`);
  const inbox = [];
  const waiters = [];

  socket.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    inbox.push(msg);
    for (let i = waiters.length - 1; i >= 0; i -= 1) {
      if (waiters[i].match(msg)) {
        waiters[i].resolve(msg);
        waiters.splice(i, 1);
      }
    }
  });

  const api2 = {
    socket,
    inbox,
    send(payload) {
      socket.send(JSON.stringify(payload));
    },
    waitFor(match, timeoutMs = 4000) {
      const predicate = typeof match === 'function' ? match : (msg) => msg.type === match;
      const existing = inbox.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          const idx = waiters.findIndex((w) => w.resolve === resolve);
          if (idx >= 0) waiters.splice(idx, 1);
          reject(new Error(`timed out waiting for socket event; inbox=${JSON.stringify(inbox).slice(0, 400)}`));
        }, timeoutMs);
        waiters.push({ match: predicate, resolve: (msg) => {
          clearTimeout(timer);
          resolve(msg);
        } });
      });
    },
    close() {
      try {
        socket.close();
      } catch {
        /* ignore */
      }
    },
    async ready() {
      return this.waitFor('ready');
    },
  };
  return api2;
}

export async function closeDatabase() {
  const { closePool } = await import('../src/db.js');
  await closePool();
}

export async function sql(text, params) {
  return pool.query(text, params);
}
