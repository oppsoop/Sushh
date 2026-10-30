import test, { after, before, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  api,
  closeDatabase,
  createUser,
  openSocket,
  request,
  resetDatabase,
  sql,
  startTestServer,
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

/** Two friends with an open conversation, plus their live sockets. */
async function friendsWithConversation() {
  const alice = await createUser(base, { displayName: 'Alice' });
  const bob = await createUser(base, { displayName: 'Bob' });
  const sent = await api(base, alice.token)('/v1/friends/requests', {
    method: 'POST',
    body: { username: bob.username },
  });
  assert.equal(sent.status, 201);
  const incoming = await api(base, bob.token)('/v1/friends/requests?direction=incoming');
  assert.equal(incoming.body.requests.length, 1);
  const requestId = incoming.body.requests[0].id;
  const accepted = await api(base, bob.token)(`/v1/friends/requests/${requestId}/accept`, { method: 'POST' });
  assert.equal(accepted.status, 200);
  return { alice, bob, conversationId: accepted.body.conversationId };
}

describe('friends', () => {
  test('request, accept, list and unfriend', async () => {
    const a = await createUser(base, { displayName: 'Anna' });
    const b = await createUser(base, { displayName: 'Ben' });

    const missing = await api(base, a.token)('/v1/friends/requests', {
      method: 'POST',
      body: { username: 'nobodyatall' },
    });
    assert.equal(missing.status, 404);

    const self = await api(base, a.token)('/v1/friends/requests', {
      method: 'POST',
      body: { username: a.username },
    });
    assert.equal(self.status, 400);

    const req = await api(base, a.token)('/v1/friends/requests', {
      method: 'POST',
      body: { username: b.username, message: 'hi!' },
    });
    assert.equal(req.status, 201);

    const duplicate = await api(base, a.token)('/v1/friends/requests', {
      method: 'POST',
      body: { username: b.username },
    });
    assert.equal(duplicate.status, 409);
    assert.equal(duplicate.body.error.code, 'request_pending');

    const outgoing = await api(base, a.token)('/v1/friends/requests?direction=outgoing');
    assert.equal(outgoing.body.requests.length, 1);
    assert.equal(outgoing.body.requests[0].user.username, b.username);

    const accepted = await api(base, b.token)(`/v1/friends/requests/${req.body.requestId}/accept`, {
      method: 'POST',
    });
    assert.equal(accepted.status, 200);
    assert.ok(accepted.body.conversationId);

    const aFriends = await api(base, a.token)('/v1/friends');
    const bFriends = await api(base, b.token)('/v1/friends');
    assert.equal(aFriends.body.friends.length, 1);
    assert.equal(bFriends.body.friends.length, 1);
    assert.equal(aFriends.body.friends[0].conversationId, accepted.body.conversationId);

    // Mutual friends: a second request resolves as already_friends with the convo.
    const again = await api(base, b.token)('/v1/friends/requests', {
      method: 'POST',
      body: { username: a.username },
    });
    assert.equal(again.body.status, 'already_friends');

    const removed = await api(base, a.token)(`/v1/friends/${b.id}`, { method: 'DELETE' });
    assert.equal(removed.status, 200);
    const afterRemove = await api(base, a.token)('/v1/friends');
    assert.equal(afterRemove.body.friends.length, 0);
  });

  test('mutual requests auto-accept, declines are respected', async () => {
    const a = await createUser(base);
    const b = await createUser(base);
    const req = await api(base, a.token)('/v1/friends/requests', { method: 'POST', body: { username: b.username } });
    const declined = await api(base, b.token)(`/v1/friends/requests/${req.body.requestId}/decline`, {
      method: 'POST',
    });
    assert.equal(declined.status, 200);

    // After a decline the reverse request is a fresh pending request...
    const reverse = await api(base, b.token)('/v1/friends/requests', { method: 'POST', body: { username: a.username } });
    assert.equal(reverse.body.status, 'pending');
    // ...and accepting it makes them friends.
    const accepted = await api(base, a.token)(`/v1/friends/requests/${reverse.body.requestId}/accept`, {
      method: 'POST',
    });
    assert.equal(accepted.status, 200);
    assert.ok(accepted.body.conversationId);
  });

  test('non-friends cannot open a chat', async () => {
    const a = await createUser(base);
    const b = await createUser(base);
    const res = await api(base, a.token)('/v1/conversations', { method: 'POST', body: { userId: b.id } });
    assert.equal(res.status, 403);
    assert.equal(res.body.error.code, 'not_friends');
  });

  test('follows work in both directions', async () => {
    const a = await createUser(base);
    const b = await createUser(base);
    const follow = await api(base, a.token)(`/v1/users/${b.id}/follow`, { method: 'POST' });
    assert.equal(follow.body.following, true);
    const followers = await api(base, b.token)(`/v1/users/${b.id}/followers`);
    assert.equal(followers.body.users.length, 1);
    const profile = await api(base, a.token)(`/v1/users/${b.username}`);
    assert.equal(profile.body.user.following, true);
    assert.equal(profile.body.user.followers, 1);
    await api(base, a.token)(`/v1/users/${b.id}/follow`, { method: 'DELETE' });
    const after = await api(base, a.token)(`/v1/users/${b.username}`);
    assert.equal(after.body.user.following, false);
  });
});

describe('realtime messaging', () => {
  test('a message is stored, fanned out over the socket and marked delivered', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const aliceSocket = openSocket(base, alice.token);
    const bobSocket = openSocket(base, bob.token);
    await aliceSocket.ready();
    await bobSocket.ready();

    const sent = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'client-msg-1', kind: 'text', body: 'Hello Bob!' },
    });
    assert.equal(sent.status, 201);
    assert.equal(sent.body.message.body, 'Hello Bob!');
    assert.equal(sent.body.message.status, 'delivered');

    const incoming = await bobSocket.waitFor((m) => m.type === 'message:new');
    assert.equal(incoming.message.body, 'Hello Bob!');
    assert.equal(incoming.conversationId, conversationId);
    assert.equal(incoming.message.senderId, alice.id);

    const status = await aliceSocket.waitFor((m) => m.type === 'message:status' && m.status === 'delivered');
    assert.equal(status.messageId, sent.body.message.id);

    const stored = await api(base, bob.token)(`/v1/conversations/${conversationId}/messages`);
    assert.equal(stored.body.messages.length, 1);
    assert.equal(stored.body.messages[0].body, 'Hello Bob!');

    aliceSocket.close();
    bobSocket.close();
  });

  test('duplicate client ids are idempotent (no duplicate rows or events)', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const bobSocket = openSocket(base, bob.token);
    await bobSocket.ready();

    const first = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'dup-1-abcdef', kind: 'text', body: 'only once' },
    });
    assert.equal(first.status, 201);

    // A double tap / offline replay sends the same client id again.
    const second = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'dup-1-abcdef', kind: 'text', body: 'only once' },
    });
    assert.equal(second.status, 200);
    assert.equal(second.body.deduplicated, true);
    assert.equal(second.body.message.id, first.body.message.id);

    const third = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'dup-1-abcdef', kind: 'text', body: 'only once' },
    });
    assert.equal(third.body.message.id, first.body.message.id);

    const { rows } = await sql('select count(*)::int as n from messages where conversation_id = $1', [conversationId]);
    assert.equal(rows[0].n, 1);

    // Exactly one realtime event reached Bob.
    const events = bobSocket.inbox.filter((m) => m.type === 'message:new' && m.message.body === 'only once');
    assert.equal(events.length, 1);
    bobSocket.close();
  });

  test('parallel duplicate sends (poor network retries) still store one message', async () => {
    const { alice, conversationId } = await friendsWithConversation();
    const results = await Promise.all(
      Array.from({ length: 5 }, () =>
        api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
          method: 'POST',
          body: { clientId: 'race-client-id', kind: 'text', body: 'race' },
        }),
      ),
    );
    const ids = new Set(results.map((r) => r.body.message.id));
    assert.equal(ids.size, 1);
    const { rows } = await sql('select count(*)::int as n from messages where conversation_id = $1', [conversationId]);
    assert.equal(rows[0].n, 1);
  });

  test('read receipts propagate and unread counts reset', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const aliceSocket = openSocket(base, alice.token);
    const bobSocket = openSocket(base, bob.token);
    await aliceSocket.ready();
    await bobSocket.ready();

    const m1 = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'read-1', kind: 'text', body: 'first' },
    });
    await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'read-2', kind: 'text', body: 'second' },
    });

    const boot = await api(base, bob.token)('/v1/auth/me');
    assert.equal(boot.body.unread.total, 2);

    bobSocket.send({ type: 'read', conversationId, messageId: m1.body.message.id });
    const readEvent = await aliceSocket.waitFor((m) => m.type === 'message:status' && m.status === 'read');
    assert.deepEqual(readEvent.messageIds, [m1.body.message.id]);

    const boot2 = await api(base, bob.token)('/v1/auth/me');
    assert.equal(boot2.body.unread.total, 1);

    bobSocket.send({ type: 'read', conversationId });
    await new Promise((r) => setTimeout(r, 300));
    const boot3 = await api(base, bob.token)('/v1/auth/me');
    assert.equal(boot3.body.unread.total, 0);

    const stored = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`);
    assert.ok(stored.body.messages.every((m) => m.status === 'read'));

    aliceSocket.close();
    bobSocket.close();
  });

  test('conversation list shows last message and unread count', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'list-1', kind: 'text', body: 'latest news' },
    });
    const list = await api(base, bob.token)('/v1/conversations');
    assert.equal(list.body.conversations.length, 1);
    const convo = list.body.conversations[0];
    assert.equal(convo.id, conversationId);
    assert.equal(convo.lastMessage.body, 'latest news');
    assert.equal(convo.unreadCount, 1);
    assert.equal(convo.peer.username, alice.username);
  });

  test('messages paginate newest-first without gaps or duplicates', async () => {
    const { alice, conversationId } = await friendsWithConversation();
    for (let i = 0; i < 25; i += 1) {
      const res = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
        method: 'POST',
        body: { clientId: `page-${i}`, kind: 'text', body: `msg ${i}` },
      });
      assert.equal(res.status, 201);
    }
    const page1 = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages?limit=10`);
    assert.equal(page1.body.messages.length, 10);
    assert.equal(page1.body.messages[9].body, 'msg 24');
    assert.ok(page1.body.nextCursor);

    const page2 = await api(base, alice.token)(
      `/v1/conversations/${conversationId}/messages?limit=10&cursor=${encodeURIComponent(page1.body.nextCursor)}`,
    );
    assert.equal(page2.body.messages.length, 10);
    assert.equal(page2.body.messages[9].body, 'msg 14');

    const page3 = await api(base, alice.token)(
      `/v1/conversations/${conversationId}/messages?limit=10&cursor=${encodeURIComponent(page2.body.nextCursor)}`,
    );
    assert.equal(page3.body.messages.length, 5);

    const all = [...page1.body.messages, ...page2.body.messages, ...page3.body.messages].map((m) => m.body);
    assert.equal(new Set(all).size, 25);
  });

  test('typing indicators are relayed to the peer only', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const aliceSocket = openSocket(base, alice.token);
    const bobSocket = openSocket(base, bob.token);
    await aliceSocket.ready();
    await bobSocket.ready();
    aliceSocket.send({ type: 'typing', conversationId, isTyping: true });
    const typing = await bobSocket.waitFor('typing');
    assert.equal(typing.userId, alice.id);
    assert.equal(typing.isTyping, true);
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(aliceSocket.inbox.filter((m) => m.type === 'typing').length, 0);
    aliceSocket.close();
    bobSocket.close();
  });

  test('sockets reject invalid tokens and can re-authenticate silently', async () => {
    const user = await createUser(base);
    const bad = openSocket(base, 'garbage-token');
    const err = await bad.waitFor('error');
    assert.equal(err.code, 'unauthorized');
    bad.close();

    const good = openSocket(base, user.token);
    await good.ready();
    const jwt = (await import('jsonwebtoken')).default;
    const fresh = jwt.sign({ sub: user.id, typ: 'access' }, process.env.JWT_SECRET, {
      expiresIn: 900,
      issuer: 'worldfriends',
      audience: 'worldfriends-app',
    });
    good.send({ type: 'auth', token: fresh });
    const ok = await good.waitFor('auth:ok');
    assert.equal(ok.userId, user.id);
    good.close();
  });

  test('deleting a message notifies the peer and hides the body', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const bobSocket = openSocket(base, bob.token);
    await bobSocket.ready();
    const sent = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'del-1-abc', kind: 'text', body: 'oops' },
    });
    await bobSocket.waitFor((m) => m.type === 'message:new');
    const del = await api(base, alice.token)(`/v1/messages/${sent.body.message.id}`, { method: 'DELETE' });
    assert.equal(del.status, 200);
    const event = await bobSocket.waitFor('message:deleted');
    assert.equal(event.messageId, sent.body.message.id);
    const stored = await api(base, bob.token)(`/v1/conversations/${conversationId}/messages`);
    assert.equal(stored.body.messages[0].body, null);
    bobSocket.close();
  });
});

describe('media in chat', () => {
  async function upload(token, { bytes, mime, name, extra = {} }) {
    const form = new FormData();
    form.append('file', new Blob([bytes], { type: mime }), name);
    for (const [key, value] of Object.entries(extra)) form.append(key, String(value));
    return request(base, '/v1/media', { method: 'POST', form, token });
  }

  test('uploads a photo and sends it as a message the peer can download', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const photo = Buffer.from('89504e470d0a1a0a-fake-png-bytes');
    const uploaded = await upload(alice.token, { bytes: photo, mime: 'image/png', name: 'photo.png', extra: { width: 800, height: 600 } });
    assert.equal(uploaded.status, 201);
    assert.equal(uploaded.body.media.kind, 'image');
    assert.equal(uploaded.body.media.width, 800);
    assert.ok(uploaded.body.media.url.includes('sig='));

    const sent = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'media-1', kind: 'image', mediaId: uploaded.body.media.id },
    });
    assert.equal(sent.status, 201);
    assert.equal(sent.body.message.kind, 'image');
    assert.equal(sent.body.message.media.id, uploaded.body.media.id);

    // The peer fetches using only the signed URL (no auth header), which is what
    // Android's image/video players do.
    const download = await fetch(`${base}${uploaded.body.media.url}`);
    assert.equal(download.status, 200);
    const downloaded = Buffer.from(await download.arrayBuffer());
    assert.equal(downloaded.toString(), photo.toString());

    // An unrelated user is refused.
    const stranger = await createUser(base);
    const denied = await api(base, stranger.token)(`/v1/media/${uploaded.body.media.id}/url`);
    assert.equal(denied.status, 403);

    // A revoked signature fails.
    const tampered = await fetch(`${base}${uploaded.body.media.url.replace(/sig=.*/, 'sig=deadbeef')}`);
    assert.equal(tampered.status, 403);
  });

  test('supports voice notes and generic files', async () => {
    const { alice, conversationId } = await friendsWithConversation();
    const voice = await upload(alice.token, {
      bytes: Buffer.from('fake-aac-audio-bytes'),
      mime: 'audio/mp4',
      name: 'voice.m4a',
      extra: { durationMs: 4200 },
    });
    assert.equal(voice.body.media.kind, 'audio');
    assert.equal(voice.body.media.durationMs, 4200);

    const file = await upload(alice.token, {
      bytes: Buffer.from('%PDF-1.4 fake pdf'),
      mime: 'application/pdf',
      name: 'doc.pdf',
    });
    assert.equal(file.body.media.kind, 'file');
    assert.equal(file.body.media.originalName, 'doc.pdf');

    const v = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'voice-1', kind: 'audio', mediaId: voice.body.media.id },
    });
    assert.equal(v.status, 201);
    const f = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'file-1', kind: 'file', mediaId: file.body.media.id },
    });
    assert.equal(f.status, 201);

    const res = await fetch(`${base}${file.body.media.url}`, { headers: { range: 'bytes=0-3' } });
    assert.equal(res.status, 206);
    const chunk = Buffer.from(await res.arrayBuffer()).toString();
    assert.equal(chunk, '%PDF');
  });

  test('rejects media that belongs to someone else', async () => {
    const { alice, conversationId } = await friendsWithConversation();
    const other = await createUser(base);
    const uploaded = await upload(other.token, { bytes: Buffer.from('x'), mime: 'image/jpeg', name: 'x.jpg' });
    const res = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'steal-1', kind: 'image', mediaId: uploaded.body.media.id },
    });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, 'invalid_media');
  });
});

describe('calls and blocking', () => {
  test('call signaling is relayed between two users and recorded', async () => {
    const { alice, bob } = await friendsWithConversation();
    const aliceSocket = openSocket(base, alice.token);
    const bobSocket = openSocket(base, bob.token);
    await aliceSocket.ready();
    await bobSocket.ready();

    const callId = '11111111-2222-3333-4444-555555555555';
    aliceSocket.send({
      type: 'call:invite',
      callId,
      toUserId: bob.id,
      kind: 'video',
      sdp: { type: 'offer', sdp: 'v=0 fake offer' },
    });

    const incoming = await bobSocket.waitFor('call:incoming');
    assert.equal(incoming.callId, callId);
    assert.equal(incoming.kind, 'video');
    assert.equal(incoming.from.username, alice.username);
    await aliceSocket.waitFor('call:ringing');

    bobSocket.send({
      type: 'call:answer',
      callId,
      toUserId: alice.id,
      sdp: { type: 'answer', sdp: 'v=0 fake answer' },
    });
    const answer = await aliceSocket.waitFor('call:answer');
    assert.equal(answer.sdp.sdp, 'v=0 fake answer');

    bobSocket.send({ type: 'call:ice', callId, toUserId: alice.id, candidate: { candidate: 'cand-1' } });
    const ice = await aliceSocket.waitFor('call:ice');
    assert.equal(ice.candidate.candidate, 'cand-1');

    aliceSocket.send({ type: 'call:end', callId, toUserId: bob.id, reason: 'hangup' });
    await bobSocket.waitFor('call:end');

    const history = await api(base, alice.token)('/v1/calls');
    assert.equal(history.body.calls.length, 1);
    assert.equal(history.body.calls[0].status, 'ended');
    assert.equal(history.body.calls[0].direction, 'outgoing');

    aliceSocket.close();
    bobSocket.close();
  });

  test('blocking stops messages both ways and hides the user from search', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    const blocked = await api(base, bob.token)(`/v1/blocks/${alice.id}`, { method: 'POST' });
    assert.equal(blocked.status, 200);

    const send = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'blocked-1', kind: 'text', body: 'hello?' },
    });
    assert.equal(send.status, 403);
    assert.equal(send.body.error.code, 'blocked');

    const reverse = await api(base, bob.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'blocked-2', kind: 'text', body: 'hello?' },
    });
    assert.equal(reverse.status, 403, 'blocking is symmetric: neither side can send');

    const search = await api(base, bob.token)(`/v1/users/search?q=${alice.username}`);
    assert.equal(search.body.results.length, 0);

    const profile = await api(base, bob.token)(`/v1/users/${alice.username}`);
    assert.equal(profile.status, 404);

    const unblocked = await api(base, bob.token)(`/v1/blocks/${alice.id}`, { method: 'DELETE' });
    assert.equal(unblocked.status, 200);
    const after = await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'unblocked-1', kind: 'text', body: 'back' },
    });
    assert.equal(after.status, 201);
  });

  test('unread counts and pending counts survive an app restart (bootstrap)', async () => {
    const { alice, bob, conversationId } = await friendsWithConversation();
    await api(base, alice.token)(`/v1/conversations/${conversationId}/messages`, {
      method: 'POST',
      body: { clientId: 'boot-1', kind: 'text', body: 'still here?' },
    });
    const third = await createUser(base);
    await api(base, third.token)('/v1/friends/requests', { method: 'POST', body: { username: bob.username } });

    const boot = await api(base, bob.token)('/v1/auth/me');
    assert.equal(boot.body.unread.total, 1);
    assert.equal(boot.body.pending.incoming, 1);
    assert.equal(boot.body.pending.notifications >= 1, true);
  });
});
