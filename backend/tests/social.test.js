import test, { after, before, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  api,
  closeDatabase,
  createUser,
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
  process.env.ADMIN_TOKEN_TEST = 'x';
});

after(async () => {
  await server?.close();
  await closeDatabase();
});

async function friendPair() {
  const a = await createUser(base, { displayName: 'Ada' });
  const b = await createUser(base, { displayName: 'Bo' });
  const req = await api(base, a.token)('/v1/friends/requests', { method: 'POST', body: { username: b.username } });
  const incoming = await api(base, b.token)('/v1/friends/requests');
  await api(base, b.token)(`/v1/friends/requests/${incoming.body.requests[0].id}/accept`, { method: 'POST' });
  return { a, b, requestId: req.body.requestId };
}

async function uploadImage(token, name = 'pic.jpg') {
  const form = new FormData();
  form.append('file', new Blob([Buffer.from('fake-image-bytes')], { type: 'image/jpeg' }), name);
  const res = await request(base, '/v1/media', { method: 'POST', form, token });
  assert.equal(res.status, 201);
  return res.body.media;
}

describe('posts, feed, likes, comments', () => {
  test('creating a post with media, then reading it from the feed', async () => {
    const { a } = await friendPair();
    const media = await uploadImage(a.token);
    const created = await api(base, a.token)('/v1/posts', {
      method: 'POST',
      body: { body: 'First post!', mediaId: media.id, visibility: 'friends' },
    });
    assert.equal(created.status, 201);
    assert.equal(created.body.post.body, 'First post!');
    assert.equal(created.body.post.media.id, media.id);
    assert.equal(created.body.post.author.username, a.username);

    const feed = await api(base, a.token)('/v1/feed');
    assert.ok(feed.body.posts.some((p) => p.id === created.body.post.id));

    const empty = await api(base, a.token)('/v1/posts', { method: 'POST', body: {} });
    assert.equal(empty.status, 400);
    assert.equal(empty.body.error.code, 'empty_post');
  });

  test('friends see friends-only posts, strangers do not', async () => {
    const { a, b } = await friendPair();
    const stranger = await createUser(base);
    const post = await api(base, a.token)('/v1/posts', {
      method: 'POST',
      body: { body: 'friends only', visibility: 'friends' },
    });
    const friendFeed = await api(base, b.token)('/v1/feed');
    assert.ok(friendFeed.body.posts.some((p) => p.id === post.body.post.id));
    const strangerFeed = await api(base, stranger.token)('/v1/feed');
    assert.equal(strangerFeed.body.posts.some((p) => p.id === post.body.post.id), false);
    const direct = await api(base, stranger.token)(`/v1/posts/${post.body.post.id}`);
    assert.equal(direct.status, 403);
  });

  test('public posts of followed users appear in the feed', async () => {
    const author = await createUser(base);
    const follower = await createUser(base);
    const post = await api(base, author.token)('/v1/posts', {
      method: 'POST',
      body: { body: 'public hello', visibility: 'public' },
    });
    const before = await api(base, follower.token)('/v1/feed');
    assert.equal(before.body.posts.some((p) => p.id === post.body.post.id), false);
    await api(base, follower.token)(`/v1/users/${author.id}/follow`, { method: 'POST' });
    const afterFollow = await api(base, follower.token)('/v1/feed');
    assert.ok(afterFollow.body.posts.some((p) => p.id === post.body.post.id));
  });

  test('likes toggle and are counted', async () => {
    const { a, b } = await friendPair();
    const post = await api(base, a.token)('/v1/posts', { method: 'POST', body: { body: 'like me' } });
    const like = await api(base, b.token)(`/v1/posts/${post.body.post.id}/like`, { method: 'POST' });
    assert.equal(like.body.liked, true);
    assert.equal(like.body.likeCount, 1);
    const again = await api(base, b.token)(`/v1/posts/${post.body.post.id}/like`, { method: 'POST' });
    assert.equal(again.body.likeCount, 1, 'liking twice is idempotent');
    const feed = await api(base, b.token)('/v1/feed');
    const row = feed.body.posts.find((p) => p.id === post.body.post.id);
    assert.equal(row.likedByMe, true);
    assert.equal(row.likeCount, 1);
    const unlike = await api(base, b.token)(`/v1/posts/${post.body.post.id}/like`, { method: 'DELETE' });
    assert.equal(unlike.body.likeCount, 0);
  });

  test('comments can be added, listed and deleted by the author', async () => {
    const { a, b } = await friendPair();
    const post = await api(base, a.token)('/v1/posts', { method: 'POST', body: { body: 'comment please' } });
    for (let i = 0; i < 3; i += 1) {
      const res = await api(base, b.token)(`/v1/posts/${post.body.post.id}/comments`, {
        method: 'POST',
        body: { body: `comment ${i}` },
      });
      assert.equal(res.status, 201);
    }
    const list = await api(base, a.token)(`/v1/posts/${post.body.post.id}/comments`);
    assert.equal(list.body.comments.length, 3);
    assert.equal(list.body.comments[0].body, 'comment 0');
    const mine = list.body.comments.find((c) => c.isMine === false);
    const del = await api(base, b.token)(`/v1/comments/${mine.id}`, { method: 'DELETE' });
    assert.equal(del.status, 200);
    const after = await api(base, a.token)(`/v1/posts/${post.body.post.id}/comments`);
    assert.equal(after.body.comments.length, 2);

    const third = await createUser(base);
    const foreign = await api(base, third.token)(`/v1/comments/${after.body.comments[0].id}`, { method: 'DELETE' });
    assert.equal(foreign.status, 403);
  });

  test('post author can delete their post', async () => {
    const { a, b } = await friendPair();
    const post = await api(base, a.token)('/v1/posts', { method: 'POST', body: { body: 'temporary' } });
    const foreign = await api(base, b.token)(`/v1/posts/${post.body.post.id}`, { method: 'DELETE' });
    assert.equal(foreign.status, 404);
    const own = await api(base, a.token)(`/v1/posts/${post.body.post.id}`, { method: 'DELETE' });
    assert.equal(own.status, 200);
    const feed = await api(base, a.token)('/v1/feed');
    assert.equal(feed.body.posts.some((p) => p.id === post.body.post.id), false);
  });

  test('feed paginates', async () => {
    const user = await createUser(base);
    for (let i = 0; i < 8; i += 1) {
      await api(base, user.token)('/v1/posts', { method: 'POST', body: { body: `post ${i}` } });
    }
    const page1 = await api(base, user.token)('/v1/feed?limit=3');
    assert.equal(page1.body.posts.length, 3);
    const page2 = await api(base, user.token)(`/v1/feed?limit=3&cursor=${encodeURIComponent(page1.body.nextCursor)}`);
    const ids1 = page1.body.posts.map((p) => p.id);
    assert.equal(page2.body.posts.some((p) => ids1.includes(p.id)), false);
  });
});

describe('stories', () => {
  test('create, list, view and expire', async () => {
    const { a, b } = await friendPair();
    const media = await uploadImage(a.token);
    const created = await api(base, a.token)('/v1/stories', {
      method: 'POST',
      body: { mediaId: media.id, caption: 'sunset' },
    });
    assert.equal(created.status, 201);
    assert.ok(new Date(created.body.story.expiresAt) > new Date(Date.now() + 23 * 3600 * 1000));

    const feed = await api(base, b.token)('/v1/stories');
    assert.equal(feed.body.groups.length, 1);
    assert.equal(feed.body.groups[0].user.username, a.username);
    assert.equal(feed.body.groups[0].stories[0].viewed, false);
    assert.equal(feed.body.groups[0].allViewed, false);

    const storyId = feed.body.groups[0].stories[0].id;
    const view = await api(base, b.token)(`/v1/stories/${storyId}/view`, { method: 'POST' });
    assert.equal(view.status, 200);
    const afterView = await api(base, b.token)('/v1/stories');
    assert.equal(afterView.body.groups[0].stories[0].viewed, true);
    assert.equal(afterView.body.groups[0].allViewed, true);

    const viewers = await api(base, a.token)(`/v1/stories/${storyId}/viewers`);
    assert.equal(viewers.body.viewers.length, 1);
    assert.equal(viewers.body.viewers[0].username, b.username);

    const notOwner = await api(base, b.token)(`/v1/stories/${storyId}/viewers`);
    assert.equal(notOwner.status, 403);

    // Expire it and confirm it disappears from the feed.
    await sql(`update stories set expires_at = now() - interval '1 minute' where id = $1`, [storyId]);
    const expired = await api(base, b.token)('/v1/stories');
    assert.equal(expired.body.groups.length, 0);
  });

  test('text-only stories are allowed, empty ones are not', async () => {
    const user = await createUser(base);
    const text = await api(base, user.token)('/v1/stories', { method: 'POST', body: { caption: 'just words' } });
    assert.equal(text.status, 201);
    const empty = await api(base, user.token)('/v1/stories', { method: 'POST', body: {} });
    assert.equal(empty.status, 400);
  });

  test('non-friends cannot see a story', async () => {
    const owner = await createUser(base);
    const stranger = await createUser(base);
    await api(base, owner.token)('/v1/stories', { method: 'POST', body: { caption: 'private-ish' } });
    const feed = await api(base, stranger.token)('/v1/stories');
    assert.equal(feed.body.groups.length, 0);
  });
});

describe('reports, analytics, feedback, translation', () => {
  test('anyone can report a post and get an id back', async () => {
    const { a, b } = await friendPair();
    const post = await api(base, a.token)('/v1/posts', { method: 'POST', body: { body: 'spammy' } });
    const report = await api(base, b.token)('/v1/reports', {
      method: 'POST',
      body: { targetType: 'post', targetId: post.body.post.id, reason: 'spam', details: 'ads' },
    });
    assert.equal(report.status, 201);
    assert.ok(report.body.id);
    const { rows } = await sql('select * from reports where id = $1', [report.body.id]);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].reason, 'spam');
  });

  test('analytics stores events but never message content', async () => {
    const user = await createUser(base);
    const res = await api(base, user.token)('/v1/analytics/events', {
      method: 'POST',
      body: {
        anonId: 'anon-123',
        appVersion: '1.0.0',
        platform: 'android',
        events: [
          { name: 'app_open', props: { cold: true } },
          { name: 'screen_view', props: { screen: 'chat' } },
          { name: 'message_sent', props: { message: 'secret text', body: 'secret', length: 11 } },
        ],
      },
    });
    assert.equal(res.status, 200);
    assert.equal(res.body.accepted, 3);
    const { rows } = await sql(
      `select name, props from analytics_events where user_id = $1 order by id`,
      [user.id],
    );
    assert.equal(rows.length, 3);
    assert.equal(rows[2].props.message, undefined);
    assert.equal(rows[2].props.body, undefined);
    assert.equal(rows[2].props.length, 11);
  });

  test('feedback accepts device info and an optional screenshot', async () => {
    const user = await createUser(base);
    const form = new FormData();
    form.append('message', 'The chat list flickers on scroll');
    form.append('appVersion', '1.0.0 (1)');
    form.append('deviceInfo', JSON.stringify({ model: 'Pixel 7', os: 'Android 14' }));
    form.append('screenshot', new Blob([Buffer.from('png-bytes')], { type: 'image/png' }), 'shot.png');
    const res = await request(base, '/v1/feedback', { method: 'POST', form, token: user.token });
    assert.equal(res.status, 201);
    const { rows } = await sql('select * from feedback where id = $1', [res.body.id]);
    assert.equal(rows[0].device_info.model, 'Pixel 7');
    assert.ok(rows[0].screenshot_media_id);
  });

  test('translation returns a clear 503 when no provider key is configured', async () => {
    const user = await createUser(base);
    const res = await api(base, user.token)('/v1/translate', {
      method: 'POST',
      body: { text: 'hola', target: 'en' },
    });
    assert.equal(res.status, 503);
    assert.equal(res.body.error.code, 'translation_not_configured');
    const langs = await api(base, user.token)('/v1/translate/languages');
    assert.equal(langs.body.configured, false);
    assert.ok(langs.body.languages.includes('en'));
  });

  test('health endpoint reports dependencies', async () => {
    const res = await request(base, '/v1/health');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'ok');
    assert.equal(res.body.database, true);
    assert.equal(typeof res.body.features.push, 'boolean');
  });

  test('unauthenticated calls are rejected everywhere they should be', async () => {
    for (const path of ['/v1/feed', '/v1/conversations', '/v1/friends', '/v1/auth/me', '/v1/notifications']) {
      const res = await request(base, path);
      assert.equal(res.status, 401, path);
    }
  });

  test('notifications list and mark read', async () => {
    const { a, b } = await friendPair();
    const list = await api(base, b.token)('/v1/notifications');
    assert.ok(list.body.notifications.length >= 1);
    assert.equal(list.body.notifications[0].kind, 'friend_request');
    const read = await api(base, b.token)('/v1/notifications/read', { method: 'POST', body: {} });
    assert.equal(read.status, 200);
    const after = await api(base, b.token)('/v1/notifications');
    assert.ok(after.body.notifications.every((n) => n.read));
    assert.ok(a);
  });

  test('device registration stores and removes push tokens', async () => {
    const user = await createUser(base);
    const reg = await api(base, user.token)('/v1/devices', {
      method: 'POST',
      body: { fcmToken: 'fake-fcm-token-123456', platform: 'android', appVersion: '1.0.0' },
    });
    assert.equal(reg.status, 200);
    const { rows } = await sql('select * from devices where user_id = $1', [user.id]);
    assert.equal(rows.length, 1);
    // Same token re-registered (app restart) updates rather than duplicates.
    await api(base, user.token)('/v1/devices', {
      method: 'POST',
      body: { fcmToken: 'fake-fcm-token-123456', platform: 'android', appVersion: '1.0.1' },
    });
    const again = await sql('select count(*)::int as n from devices where user_id = $1', [user.id]);
    assert.equal(again.rows[0].n, 1);
    const removed = await api(base, user.token)('/v1/devices?fcmToken=fake-fcm-token-123456', { method: 'DELETE' });
    assert.equal(removed.status, 200);
  });
});

describe('admin', () => {
  test('invite creation requires the admin token', async () => {
    const denied = await request(base, '/v1/admin/invites', { method: 'POST', body: {} });
    assert.equal(denied.status, 404);
  });
});
