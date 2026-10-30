import test, { after, before, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  closeDatabase,
  createUser,
  request,
  resetDatabase,
  sql,
  startTestServer,
  uniqueEmail,
} from './harness.js';

let server;
let base;

before(async () => {
  await resetDatabase();
  server = await startTestServer();
  base = server.baseUrl;
});

after(async () => {
  await server?.close();
  await closeDatabase();
});

describe('beta gate', () => {
  test('blocks unknown emails in beta mode', async () => {
    const res = await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email: uniqueEmail('stranger'), password: 'Passw0rd!23' },
    });
    assert.equal(res.status, 403);
    assert.equal(res.body.error.code, 'beta_closed');
  });

  test('allows allow-listed emails', async () => {
    const res = await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email: 'vip@example.com', password: 'Passw0rd!23' },
    });
    assert.equal(res.status, 201);
  });

  test('allows valid invite codes and rejects invalid ones', async () => {
    const bad = await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email: uniqueEmail('invitee'), password: 'Passw0rd!23', inviteCode: 'NOPE' },
    });
    assert.equal(bad.status, 403);

    const good = await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email: uniqueEmail('invitee'), password: 'Passw0rd!23', inviteCode: 'FRIENDS2026' },
    });
    assert.equal(good.status, 201);
  });

  test('exposes beta config for the badge', async () => {
    const res = await request(base, '/v1/beta/config');
    assert.equal(res.status, 200);
    assert.equal(res.body.betaMode, true);
    assert.equal(res.body.showBetaBadge, true);
  });
});

describe('email verification and session', () => {
  test('rejects a wrong verification code, accepts the real one', async () => {
    const email = uniqueEmail('verify');
    const reg = await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email, password: 'Passw0rd!23', displayName: 'Verifier', inviteCode: 'FRIENDS2026' },
    });
    assert.equal(reg.status, 201);
    assert.equal(typeof reg.body.devCode, 'string');

    const wrong = await request(base, '/v1/auth/verify-email', {
      method: 'POST',
      body: { email, code: '000000' },
    });
    assert.equal(wrong.status, 400);
    assert.equal(wrong.body.error.code, 'invalid_code');

    const ok = await request(base, '/v1/auth/verify-email', {
      method: 'POST',
      body: { email, code: reg.body.devCode },
    });
    assert.equal(ok.status, 200);
    assert.ok(ok.body.accessToken);
    assert.ok(ok.body.refreshToken);
    assert.equal(ok.body.needsUsername, true);
    assert.equal(ok.body.user.emailVerified, true);
    assert.deepEqual(ok.body.usernameIdeas.length > 0, true);

    // The same code must not work twice.
    const replay = await request(base, '/v1/auth/verify-email', {
      method: 'POST',
      body: { email, code: reg.body.devCode },
    });
    assert.equal(replay.status, 400);
  });

  test('login is refused until the email is verified', async () => {
    const email = uniqueEmail('unverified');
    const password = 'Passw0rd!23';
    await request(base, '/v1/auth/register', {
      method: 'POST',
      body: { email, password, inviteCode: 'FRIENDS2026' },
    });

    const login = await request(base, '/v1/auth/login', { method: 'POST', body: { email, password } });
    assert.equal(login.status, 403);
    assert.equal(login.body.error.code, 'email_not_verified');
    assert.equal(login.body.error.details.canResend, true);

    const resent = await request(base, '/v1/auth/resend-verification', { method: 'POST', body: { email } });
    assert.equal(resent.status, 200);
    const ok = await request(base, '/v1/auth/verify-email', {
      method: 'POST',
      body: { email, code: resent.body.devCode },
    });
    assert.equal(ok.status, 200);

    const login2 = await request(base, '/v1/auth/login', { method: 'POST', body: { email, password } });
    assert.equal(login2.status, 200);
    assert.ok(login2.body.accessToken);
  });

  test('login rejects a wrong password without revealing existence', async () => {
    const user = await createUser(base);
    const res = await request(base, '/v1/auth/login', {
      method: 'POST',
      body: { email: user.email, password: 'wrong-password' },
    });
    assert.equal(res.status, 401);
    assert.equal(res.body.error.code, 'invalid_credentials');

    const ghost = await request(base, '/v1/auth/login', {
      method: 'POST',
      body: { email: uniqueEmail('ghost'), password: 'wrong-password' },
    });
    assert.equal(ghost.status, 401);
    assert.equal(ghost.body.error.code, 'invalid_credentials');
  });

  test('refresh rotates tokens and detects replay', async () => {
    const user = await createUser(base);
    const first = await request(base, '/v1/auth/refresh', {
      method: 'POST',
      body: { refreshToken: user.refreshToken },
    });
    assert.equal(first.status, 200);
    assert.ok(first.body.accessToken);
    assert.notEqual(first.body.refreshToken, user.refreshToken);

    // Replaying the consumed token must kill the whole family.
    const replay = await request(base, '/v1/auth/refresh', {
      method: 'POST',
      body: { refreshToken: user.refreshToken },
    });
    assert.equal(replay.status, 401);
    assert.equal(replay.body.error.code, 'refresh_token_reused');

    const afterReuse = await request(base, '/v1/auth/refresh', {
      method: 'POST',
      body: { refreshToken: first.body.refreshToken },
    });
    assert.equal(afterReuse.status, 401);
  });

  test('logout revokes the refresh token', async () => {
    const user = await createUser(base);
    const out = await request(base, '/v1/auth/logout', {
      method: 'POST',
      body: { refreshToken: user.refreshToken },
    });
    assert.equal(out.status, 200);
    const refresh = await request(base, '/v1/auth/refresh', {
      method: 'POST',
      body: { refreshToken: user.refreshToken },
    });
    assert.equal(refresh.status, 401);
  });

  test('password reset flow works and revokes old sessions', async () => {
    const user = await createUser(base);
    const forgot = await request(base, '/v1/auth/password/forgot', {
      method: 'POST',
      body: { email: user.email },
    });
    assert.equal(forgot.status, 200);
    const code = forgot.body.devCode;

    const reset = await request(base, '/v1/auth/password/reset', {
      method: 'POST',
      body: { email: user.email, code, newPassword: 'BrandNewPass!9' },
    });
    assert.equal(reset.status, 200);
    assert.ok(reset.body.accessToken);

    const oldRefresh = await request(base, '/v1/auth/refresh', {
      method: 'POST',
      body: { refreshToken: user.refreshToken },
    });
    assert.equal(oldRefresh.status, 401);

    const oldLogin = await request(base, '/v1/auth/login', {
      method: 'POST',
      body: { email: user.email, password: user.password },
    });
    assert.equal(oldLogin.status, 401);

    const newLogin = await request(base, '/v1/auth/login', {
      method: 'POST',
      body: { email: user.email, password: 'BrandNewPass!9' },
    });
    assert.equal(newLogin.status, 200);
  });

  test('password reset with an unknown email still returns 200 (no enumeration)', async () => {
    const res = await request(base, '/v1/auth/password/forgot', {
      method: 'POST',
      body: { email: uniqueEmail('nobody') },
    });
    assert.equal(res.status, 200);
  });

  test('bootstrap returns user, unread counts and feature flags', async () => {
    const user = await createUser(base);
    const me = await request(base, '/v1/auth/me', { token: user.token });
    assert.equal(me.status, 200);
    assert.equal(me.body.user.username, user.username);
    assert.equal(me.body.user.needsUsername, false);
    assert.equal(typeof me.body.unread.total, 'number');
    assert.equal(me.body.beta.betaMode, true);
    assert.equal(typeof me.body.features.translation, 'boolean');
  });

  test('expired access tokens are rejected with a distinguishable code', async () => {
    const user = await createUser(base);
    const jwt = (await import('jsonwebtoken')).default;
    const expired = jwt.sign({ sub: user.id, typ: 'access' }, process.env.JWT_SECRET, {
      expiresIn: -10,
      issuer: 'worldfriends',
      audience: 'worldfriends-app',
    });
    const res = await request(base, '/v1/auth/me', { token: expired });
    assert.equal(res.status, 401);
    assert.equal(res.body.error.code, 'token_expired');
  });

  test('google sign-in is 503 until client ids are configured', async () => {
    const res = await request(base, '/v1/auth/google', { method: 'POST', body: { idToken: 'x'.repeat(40) } });
    assert.equal(res.status, 503);
    assert.equal(res.body.error.code, 'google_signin_not_configured');
  });
});

describe('account deletion', () => {
  test('requires the password, deactivates the account and frees the username', async () => {
    const user = await createUser(base);
    const wrong = await request(base, '/v1/users/me', {
      method: 'DELETE',
      body: { password: 'nope', confirm: 'DELETE' },
      token: user.token,
    });
    assert.equal(wrong.status, 401);

    const missingConfirm = await request(base, '/v1/users/me', {
      method: 'DELETE',
      body: { password: user.password },
      token: user.token,
    });
    assert.equal(missingConfirm.status, 400);

    const ok = await request(base, '/v1/users/me', {
      method: 'DELETE',
      body: { password: user.password, confirm: 'DELETE' },
      token: user.token,
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.status, 'deleted');

    // The access token still parses, but the account is gone.
    const me = await request(base, '/v1/auth/me', { token: user.token });
    assert.equal(me.status, 401);

    const login = await request(base, '/v1/auth/login', {
      method: 'POST',
      body: { email: user.email, password: user.password },
    });
    assert.equal(login.status, 403);
    assert.equal(login.body.error.code, 'account_deleted');

    const { rows } = await sql('select 1 from username_history where username = $1', [user.username]);
    assert.equal(rows.length, 1);
  });
});
