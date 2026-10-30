import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { api, closeDatabase, createUnclaimedUser, createUser, openSocket, request, resetDatabase, sql, startTestServer, uniqueEmail } from './harness.js';
import { expireStories, purgeDeletedAccounts } from '../src/jobs.js';
import { putObject, signedMediaUrl } from '../src/storage.js';
import { suggestionsFor, validateUsername } from '../src/username.js';

let server, base;
before(async () => { await resetDatabase(); server = await startTestServer(); base = server.baseUrl; });
after(async () => { await server?.close(); await closeDatabase(); });

async function connectFriends(a, b) {
  const sent = await api(base, a.token)('/v1/friends/requests', { method: 'POST', body: { userId: b.id } });
  assert.equal(sent.status, 201);
  const accepted = await api(base, b.token)(`/v1/friends/requests/${sent.body.requestId}/accept`, { method: 'POST' });
  assert.equal(accepted.status, 200);
  return accepted.body.conversationId;
}

test('mailbox owner chooses the verified password even if someone pre-registered their email', async () => {
  const email = uniqueEmail('preregister');
  const attack = await request(base, '/v1/auth/register', { method: 'POST', body: {
    email, password: 'AttackerPassword9!', inviteCode: 'FRIENDS2026',
  }});
  assert.equal(attack.status, 201);
  const owner = await request(base, '/v1/auth/register', { method: 'POST', body: {
    email, password: 'OwnerPassword9!', inviteCode: 'FRIENDS2026',
  }});
  assert.equal(owner.status, 200);
  const verified = await request(base, '/v1/auth/verify-email', { method: 'POST', body: {
    email, code: owner.body.devCode, password: 'OwnerPassword9!',
  }});
  assert.equal(verified.status, 200);
  const oldLogin = await request(base, '/v1/auth/login', { method: 'POST', body: { email, password: 'AttackerPassword9!' } });
  const newLogin = await request(base, '/v1/auth/login', { method: 'POST', body: { email, password: 'OwnerPassword9!' } });
  assert.equal(oldLogin.status, 401);
  assert.equal(newLogin.status, 200);
  const stored = await sql("select token_hash from email_tokens where user_id = $1 and purpose = 'verify_email'", [verified.body.user.id]);
  assert.ok(stored.rows.every((row) => !row.token_hash.includes(owner.body.devCode)));
});

test('verification codes are single-use under simultaneous submissions', async () => {
  const email = uniqueEmail('verifyrace');
  const password = 'Password123!';
  const reg = await request(base, '/v1/auth/register', { method: 'POST', body: { email, password, inviteCode: 'FRIENDS2026' } });
  const results = await Promise.all(Array.from({ length: 2 }, () => request(base, '/v1/auth/verify-email', {
    method: 'POST', body: { email, code: reg.body.devCode, password },
  })));
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 400]);
});

test('concurrent refresh cannot mint two valid token families', async () => {
  const user = await createUser(base);
  const results = await Promise.all(Array.from({ length: 2 }, () => request(base, '/v1/auth/refresh', {
    method: 'POST', body: { refreshToken: user.refreshToken },
  })));
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 401]);
  const child = results.find((r) => r.status === 200).body.refreshToken;
  assert.equal((await request(base, '/v1/auth/refresh', { method: 'POST', body: { refreshToken: child } })).status, 401);
});

test('reserved words cannot be embedded and 20-character names yield valid alternatives', () => {
  for (const name of ['adminjoe', 'best.support', 'myteam42', 'fakeofficial']) {
    assert.equal(validateUsername(name).ok, false, name);
  }
  const ideas = suggestionsFor('abcdefghijklmnopqrst');
  assert.equal(ideas.length, 3);
  for (const idea of ideas) { assert.ok(idea.length <= 20); assert.equal(validateUsername(idea).ok, true); }
});

test('an account must claim a username before accessing onboarded features', async () => {
  const user = await createUnclaimedUser(base);
  const result = await api(base, user.token)('/v1/posts', { method: 'POST', body: { body: 'hello' } });
  assert.equal(result.status, 403);
  assert.equal(result.body.error.code, 'username_required');
});

test('search matches @exact names and substrings of usernames', async () => {
  const target = await createUser(base, { username: 'marigold' });
  const searcher = await createUser(base);
  const exact = await api(base, searcher.token)('/v1/users/search?q=%40marigold');
  const partial = await api(base, searcher.token)('/v1/users/search?q=rigol');
  assert.equal(exact.body.results[0].id, target.id);
  assert.ok(partial.body.results.some((x) => x.id === target.id));
});

test('private posts and their comments cannot be viewed or liked by friends or strangers', async () => {
  const a = await createUser(base); const b = await createUser(base); const stranger = await createUser(base);
  await connectFriends(a, b);
  const post = await api(base, a.token)('/v1/posts', { method: 'POST', body: { body: 'private', visibility: 'private' } });
  const id = post.body.post.id;
  await api(base, a.token)(`/v1/posts/${id}/comments`, { method: 'POST', body: { body: 'secret' } });
  for (const viewer of [b, stranger]) {
    assert.equal((await api(base, viewer.token)(`/v1/posts/${id}`)).status, 403);
    assert.equal((await api(base, viewer.token)(`/v1/posts/${id}/comments`)).status, 403);
    assert.equal((await api(base, viewer.token)(`/v1/posts/${id}/like`, { method: 'POST' })).status, 403);
    assert.equal((await api(base, viewer.token)(`/v1/posts/${id}/comments`, { method: 'POST', body: { body: 'no' } })).status, 403);
    const profile = await api(base, viewer.token)(`/v1/users/${a.username}/posts`);
    assert.ok(!profile.body.posts.some((x) => x.id === id));
  }
});

test('an unrelated user cannot invite or control someone else’s call', async () => {
  const a = await createUser(base); const b = await createUser(base); const attacker = await createUser(base);
  await connectFriends(a, b);
  const as = openSocket(base, a.token); const bs = openSocket(base, b.token); const xs = openSocket(base, attacker.token);
  try {
    await Promise.all([as.ready(), bs.ready(), xs.ready()]);
    xs.send({ type: 'call:invite', callId: crypto.randomUUID(), toUserId: b.id, kind: 'audio' });
    assert.equal((await xs.waitFor('call:failed')).reason, 'not_allowed');
    const callId = crypto.randomUUID();
    as.send({ type: 'call:invite', callId, toUserId: b.id, kind: 'audio', sdp: { type: 'offer', sdp: 'v=0' } });
    await bs.waitFor('call:incoming');
    xs.send({ type: 'call:end', callId, toUserId: b.id });
    xs.send({ type: 'ping' });
    await xs.waitFor('pong');
    const state = await sql('select status, ended_at from calls where id = $1', [callId]);
    assert.equal(state.rows[0].status, 'ringing');
    assert.equal(state.rows[0].ended_at, null);
  } finally { as.close(); bs.close(); xs.close(); }
});

test('story expiration does not delete media that is also used in a post', async () => {
  const owner = await createUser(base);
  const form = new FormData();
  form.append('file', new Blob(['shared bytes'], { type: 'image/jpeg' }), 'shared.jpg');
  const uploaded = await request(base, '/v1/media', { method: 'POST', token: owner.token, form });
  const media = uploaded.body.media;
  await api(base, owner.token)('/v1/posts', { method: 'POST', body: { body: 'kept', mediaId: media.id } });
  const story = await api(base, owner.token)('/v1/stories', { method: 'POST', body: { mediaId: media.id } });
  await sql("update stories set expires_at = now() - interval '1 minute' where id = $1", [story.body.story.id]);
  await expireStories();
  assert.equal((await api(base, owner.token)(`/v1/media/${media.id}`)).status, 200);
  assert.equal((await fetch(base + media.url)).status, 200);
});

test('a one-use beta invite cannot be consumed twice in a registration race', async () => {
  const inviteId = crypto.randomUUID();
  const code = 'ONE-' + crypto.randomBytes(4).toString('hex');
  await sql('insert into beta_invites (id, code, max_uses) values ($1, $2, 1)', [inviteId, code]);
  const results = await Promise.all(Array.from({ length: 2 }, (_, i) => request(base, '/v1/auth/register', {
    method: 'POST', body: { email: uniqueEmail(`slot${i}`), password: 'Password123!', inviteCode: code },
  })));
  assert.deepEqual(results.map((r) => r.status).sort(), [201, 403]);
  const result = await sql('select used_count from beta_invites where id = $1', [inviteId]);
  assert.equal(result.rows[0].used_count, 1);
});

test('incoming call recovery is available only to the callee and contains queued ICE', async () => {
  const a = await createUser(base); const b = await createUser(base); const stranger = await createUser(base);
  await connectFriends(a, b);
  const as = openSocket(base, a.token);
  try {
    await as.ready();
    const callId = crypto.randomUUID();
    as.send({ type: 'call:invite', callId, toUserId: b.id, kind: 'audio', sdp: { type: 'offer', sdp: 'v=0' } });
    await as.waitFor('call:ringing');
    as.send({ type: 'call:ice', callId, toUserId: b.id, candidate: { candidate: 'early-ice' } });
    await as.waitFor((m) => m.type === 'call:ack' && m.event === 'ice');
    const incoming = await api(base, b.token)(`/v1/calls/${callId}/incoming`);
    assert.equal(incoming.status, 200);
    assert.equal(incoming.body.sdp.sdp, 'v=0');
    assert.equal(incoming.body.candidates[0].candidate, 'early-ice');
    assert.equal((await api(base, stranger.token)(`/v1/calls/${callId}/incoming`)).status, 404);
    assert.equal((await api(base, a.token)(`/v1/calls/${callId}/incoming`)).status, 404);
  } finally { as.close(); }
});

test('owner-only endpoints require an admin header and create unguessable invites', async () => {
  const input = { method: 'POST', body: { maxUses: 1, email: uniqueEmail('invited') } };
  assert.equal((await request(base, '/v1/admin/invites', input)).status, 404);
  assert.equal((await request(base, '/v1/admin/invites?adminToken=test-owner-token-do-not-use', input)).status, 404);
  const created = await request(base, '/v1/admin/invites', { ...input, headers: { 'x-admin-token': 'test-owner-token-do-not-use' } });
  assert.equal(created.status, 201);
  assert.match(created.body.invite.code, /^WF-[A-Za-z0-9_-]{24}$/);
  const otherEmail = await request(base, '/v1/auth/register', { method: 'POST', body: {
    email: uniqueEmail('other'), password: 'Password123!', inviteCode: created.body.invite.code,
  }});
  assert.equal(otherEmail.status, 403);
});

test('deleting an account immediately hides authored content and later purges media', async () => {
  const author = await createUser(base); const friend = await createUser(base);
  const conversation = await connectFriends(author, friend);
  const mediaId = crypto.randomUUID(); const postId = crypto.randomUUID(); const messageId = crypto.randomUUID();
  const key = `purge/${mediaId}.txt`;
  await putObject(key, Buffer.from('private attachment'), 'text/plain');
  await sql(`insert into media (id, owner_id, kind, mime, bytes, storage_key) values ($1,$2,'file','text/plain',18,$3)`, [mediaId, author.id, key]);
  await sql(`insert into posts (id, user_id, body, visibility) values ($1,$2,'private post','public')`, [postId, author.id]);
  await sql(`insert into messages (id, conversation_id, sender_id, client_id, body) values ($1,$2,$3,'purge-test','private message')`, [messageId, conversation, author.id]);
  const oldLink = signedMediaUrl(mediaId);
  assert.equal((await request(base, oldLink)).status, 200);
  const deleted = await request(base, '/v1/users/me', { method: 'DELETE', token: author.token, body: { password: author.password, confirm: 'DELETE' } });
  assert.equal(deleted.status, 200);
  assert.equal((await request(base, oldLink)).status, 404);
  assert.equal((await api(base, friend.token)(`/v1/posts/${postId}`)).status, 404);
  const message = await sql('select body, deleted_at from messages where id = $1', [messageId]);
  assert.equal(message.rows[0].body, null); assert.ok(message.rows[0].deleted_at);
  await sql("update users set deleted_at = now() - interval '31 days' where id = $1", [author.id]);
  assert.ok(await purgeDeletedAccounts() >= 1);
  assert.equal((await sql('select id from users where id = $1', [author.id])).rowCount, 0);
  assert.equal((await sql('select id from media where id = $1', [mediaId])).rowCount, 0);
  assert.equal((await sql('select username from username_history where user_id = $1', [author.id])).rowCount, 1);
});
