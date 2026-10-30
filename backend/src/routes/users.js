import express from 'express';
import { z } from 'zod';
import { env } from '../env.js';
import { query } from '../db.js';
import { asyncRoute, badRequest, conflict, notFound, forbidden, unauthorized } from '../errors.js';
import { requireAuth, revokeAllSessions } from '../auth.js';
import { rateLimit } from '../ratelimit.js';
import { areFriends, blockedEither, createFriendship, ensureDirectConversation, friendIds, removeFriendship } from '../friends.js';
import { getUserById, getUserByUsername, otherUser, selfUser } from '../service.js';
import { decodeCursor, decodeValues, encodeCursor, encodeValues, pageLimit, uuid, verifyPassword } from '../util.js';
import { signedMediaUrl } from '../storage.js';
import { broadcastToUser, isOnline, sendToUser } from '../realtime.js';

const router = express.Router();

/* ------------------------------------------------------------------ *
 * Search
 * ------------------------------------------------------------------ */

router.get(
  '/users/search',
  requireAuth,
  rateLimit({ limit: 90, windowMs: 60 * 1000, keyPrefix: 'search' }),
  asyncRoute(async (req, res) => {
    const q = String(req.query.q || '').trim();
    const limit = pageLimit(req.query.limit, 20, 50);
    const cursor = decodeValues(req.query.cursor, 3);
    if (q.length < 1) return res.json({ results: [], nextCursor: null });

    const normalized = q.replace(/^@/, '').toLowerCase();
    const escapeLike = (value) => value.replace(/[\\%_]/g, (m) => `\\${m}`);
    const like = `${escapeLike(normalized)}%`;
    const contains = `%${escapeLike(q.replace(/^@/, ''))}%`;
    const usernameContains = `%${escapeLike(normalized)}%`;

    const { rows } = await query(
      `select u.*, f.user_a is not null as is_friend,
              (select 1 from friend_requests fr
                where fr.status = 'pending'
                  and ((fr.from_user_id = $1 and fr.to_user_id = u.id) or (fr.from_user_id = u.id and fr.to_user_id = $1))
                limit 1) as has_pending
         from users u
         left join friendships f
           on (f.user_a = least(u.id, $1::uuid) and f.user_b = greatest(u.id, $1::uuid))
        where u.id <> $1
          and u.deleted_at is null
          and u.username is not null
          and u.email_verified_at is not null
          and not exists (
            select 1 from blocks b
             where (b.blocker_id = $1 and b.blocked_id = u.id) or (b.blocker_id = u.id and b.blocked_id = $1)
          )
          and ($4::int is null or (
                case when u.username = $2 then 0 when u.username like $3 escape '\\' then 1 else 2 end,
                u.username, u.id
              ) > ($4::int, $5::text, $6::uuid))
          and (u.username = $2 or u.username like $8 escape '\\' or u.display_name ilike $7 escape '\\')
        order by
          case when u.username = $2 then 0
               when u.username like $3 escape '\\' then 1
               else 2 end,
          u.username asc, u.id asc
        limit $9`,
      [
        req.userId,
        normalized,
        like,
        cursor ? Number(cursor[0]) : null,
        cursor ? cursor[1] : null,
        cursor ? cursor[2] : null,
        contains,
        usernameContains,
        limit + 1,
      ],
    );

    const hasMore = rows.length > limit;
    const page = rows.slice(0, limit);
    res.json({
      results: page.map((row) => ({
        ...otherUser(row, {
          isFriend: Boolean(row.is_friend),
          requestPending: Boolean(row.has_pending),
          online: isOnline(row.id),
        }),
        matchType: row.username === normalized ? 'exact' : row.username?.startsWith(normalized) ? 'prefix' : 'display',
      })),
      nextCursor: hasMore
        ? encodeValues([
            page[page.length - 1].username === normalized
              ? 0
              : page[page.length - 1].username?.startsWith(normalized)
                ? 1
                : 2,
            page[page.length - 1].username,
            page[page.length - 1].id,
          ])
        : null,
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Profile
 * ------------------------------------------------------------------ */

router.get(
  '/users/me',
  requireAuth,
  asyncRoute(async (req, res) => {
    const user = await getUserById(req.userId);
    res.json({ user: selfUser(user) });
  }),
);

router.patch(
  '/users/me',
  requireAuth,
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        displayName: z.string().trim().min(1).max(60).optional(),
        bio: z.string().trim().max(300).optional(),
        avatarMediaId: z.string().uuid().nullable().optional(),
      })
      .parse(req.body);

    if (body.avatarMediaId) {
      const { rows } = await query('select owner_id from media where id = $1 and deleted_at is null', [
        body.avatarMediaId,
      ]);
      if (!rows[0] || rows[0].owner_id !== req.userId) throw badRequest('invalid_media', 'Unknown media');
    }

    const { rows } = await query(
      `update users set
          display_name = coalesce($2, display_name),
          bio = coalesce($3, bio),
          avatar_media_id = coalesce($4, avatar_media_id),
          updated_at = now()
        where id = $1
        returning *`,
      [req.userId, body.displayName ?? null, body.bio ?? null, body.avatarMediaId ?? null],
    );
    res.json({ user: selfUser(rows[0]) });
  }),
);

router.get(
  '/users/:username',
  requireAuth,
  asyncRoute(async (req, res) => {
    const username = String(req.params.username).replace(/^@/, '').toLowerCase();
    const target = await getUserByUsername(username);
    if (!target || target.deleted_at || !target.username) throw notFound('user_not_found', 'No such username');
    if (await blockedEither(req.userId, target.id)) throw notFound('user_not_found', 'No such username');

    const { rows: counts } = await query(
      `select
         (select count(*)::int from follows where following_id = $1) as followers,
         (select count(*)::int from follows where follower_id = $1) as following,
         (select count(*)::int from posts where user_id = $1 and deleted_at is null) as posts`,
      [target.id],
    );
    const { rows: rel } = await query(
      `select
         exists(select 1 from friendships where user_a = least($1::uuid,$2::uuid) and user_b = greatest($1::uuid,$2::uuid)) as is_friend,
         exists(select 1 from follows where follower_id = $1 and following_id = $2) as following,
         (select id from friend_requests where from_user_id = $1 and to_user_id = $2 and status = 'pending') as outgoing_request,
         (select id from friend_requests where from_user_id = $2 and to_user_id = $1 and status = 'pending') as incoming_request`,
      [req.userId, target.id],
    );
    res.json({
      user: otherUser(target, {
        online: isOnline(target.id),
        followers: counts[0]?.followers ?? 0,
        followingCount: counts[0]?.following ?? 0,
        posts: counts[0]?.posts ?? 0,
        isMe: target.id === req.userId,
        isFriend: rel[0].is_friend,
        following: rel[0].following,
        outgoingRequestId: rel[0].outgoing_request,
        incomingRequestId: rel[0].incoming_request,
      }),
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Friends & requests
 * ------------------------------------------------------------------ */

router.get(
  '/friends',
  requireAuth,
  asyncRoute(async (req, res) => {
    const limit = pageLimit(req.query.limit, 50, 100);
    const { rows } = await query(
      `select u.*, cm.conversation_id
         from friendships f
         join users u on u.id = case when f.user_a = $1 then f.user_b else f.user_a end
         left join lateral (
           select id as conversation_id from conversations
            where pair_key = (least($1::uuid, u.id)::text || ':' || greatest($1::uuid, u.id)::text)
         ) cm on true
        where (f.user_a = $1 or f.user_b = $1) and u.deleted_at is null
        order by u.display_name asc
        limit $2`,
      [req.userId, limit],
    );
    res.json({
      friends: rows.map((row) => ({
        ...otherUser(row, { online: isOnline(row.id), conversationId: row.conversation_id }),
        isFriend: true,
      })),
    });
  }),
);

router.post(
  '/friends/requests',
  requireAuth,
  rateLimit({ limit: 40, windowMs: 60 * 60 * 1000, keyPrefix: 'friend-req' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        username: z.string().trim().max(30).optional(),
        userId: z.string().uuid().optional(),
        message: z.string().trim().max(200).optional(),
      })
      .parse(req.body);
    if (!body.username && !body.userId) throw badRequest('missing_target', 'Provide a username or user id');

    const target = body.userId ? await getUserById(body.userId) : await getUserByUsername(body.username.replace(/^@/, ''));
    if (!target || target.deleted_at || !target.username) throw notFound('user_not_found', 'No such username');
    if (target.id === req.userId) throw badRequest('self_request', 'You cannot add yourself');
    if (await blockedEither(req.userId, target.id)) throw notFound('user_not_found', 'No such username');
    if (await areFriends(req.userId, target.id)) {
      const conversationId = await ensureDirectConversation(req.userId, target.id);
      return res.status(200).json({ status: 'already_friends', conversationId });
    }

    // If they already asked us, accept instead of creating a second request.
    const { rows: incoming } = await query(
      `select id from friend_requests where from_user_id = $1 and to_user_id = $2 and status = 'pending'`,
      [target.id, req.userId],
    );
    if (incoming[0]) {
      await query(`update friend_requests set status = 'accepted', responded_at = now() where id = $1`, [incoming[0].id]);
      await createFriendship(req.userId, target.id);
      const conversationId = await ensureDirectConversation(req.userId, target.id);
      broadcastToUser(target.id, { type: 'friend:accepted', userId: req.userId, conversationId });
      return res.json({ status: 'accepted', conversationId, requestId: incoming[0].id });
    }

    const id = uuid();
    try {
      await query(
        `insert into friend_requests (id, from_user_id, to_user_id, message) values ($1, $2, $3, $4)`,
        [id, req.userId, target.id, body.message || null],
      );
    } catch (err) {
      if (err.code === '23505') throw conflict('request_pending', 'You already sent a request to this person.');
      throw err;
    }

    const me = await getUserById(req.userId);
    await query(
      `insert into notifications (id, user_id, kind, actor_id, entity_type, entity_id, data)
       values ($1, $2, 'friend_request', $3, 'friend_request', $4, $5)`,
      [uuid(), target.id, req.userId, id, JSON.stringify({ fromUsername: me.username, fromName: me.display_name })],
    );
    sendToUser(target.id, {
      type: 'friend:request',
      requestId: id,
      from: otherUser(me),
    });
    const { sendPushToUser } = await import('../push.js');
    sendPushToUser(target.id, {
      title: 'New friend request',
      body: `${me.display_name || me.username} wants to connect on WorldFriends`,
      data: { type: 'friend_request', requestId: id },
      channelId: 'social',
    }).catch(() => {});

    res.status(201).json({ status: 'pending', requestId: id });
  }),
);

router.get(
  '/friends/requests',
  requireAuth,
  asyncRoute(async (req, res) => {
    const direction = req.query.direction === 'outgoing' ? 'outgoing' : 'incoming';
    const limit = pageLimit(req.query.limit, 30, 100);
    const cursor = decodeCursor(req.query.cursor);
    const column = direction === 'incoming' ? 'fr.to_user_id' : 'fr.from_user_id';
    const other = direction === 'incoming' ? 'fr.from_user_id' : 'fr.to_user_id';
    const { rows } = await query(
      `select fr.*, u.username, u.display_name, u.bio, u.avatar_media_id, u.last_seen_at
         from friend_requests fr
         join users u on u.id = ${other}
        where ${column} = $1 and fr.status = 'pending'
          and ($2::timestamptz is null or (fr.created_at, fr.id) < ($2::timestamptz, $3::uuid))
        order by fr.created_at desc, fr.id desc
        limit $4`,
      [req.userId, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );
    const page = rows.slice(0, limit);
    res.json({
      requests: page.map((row) => ({
        id: row.id,
        direction,
        status: row.status,
        message: row.message,
        createdAt: row.created_at,
        user: otherUser(row, { online: isOnline(row.id) }),
      })),
      nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1].created_at, page[page.length - 1].id) : null,
    });
  }),
);

router.post(
  '/friends/requests/:id/accept',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select * from friend_requests where id = $1 and to_user_id = $2 and status = 'pending'`,
      [req.params.id, req.userId],
    );
    const request = rows[0];
    if (!request) throw notFound('request_not_found', 'That request is no longer pending');
    await query(`update friend_requests set status = 'accepted', responded_at = now() where id = $1`, [request.id]);
    await createFriendship(request.from_user_id, request.to_user_id);
    const conversationId = await ensureDirectConversation(request.from_user_id, request.to_user_id);
    broadcastToUser(request.from_user_id, { type: 'friend:accepted', userId: req.userId, conversationId });
    res.json({ status: 'accepted', conversationId });
  }),
);

router.post(
  '/friends/requests/:id/decline',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rowCount } = await query(
      `update friend_requests set status = 'declined', responded_at = now()
        where id = $1 and to_user_id = $2 and status = 'pending'`,
      [req.params.id, req.userId],
    );
    if (!rowCount) throw notFound('request_not_found', 'That request is no longer pending');
    res.json({ status: 'declined' });
  }),
);

router.delete(
  '/friends/:userId',
  requireAuth,
  asyncRoute(async (req, res) => {
    await removeFriendship(req.userId, req.params.userId);
    broadcastToUser(req.params.userId, { type: 'friend:removed', userId: req.userId });
    res.json({ status: 'removed' });
  }),
);

/* ------------------------------------------------------------------ *
 * Follows
 * ------------------------------------------------------------------ */

router.post(
  '/users/:userId/follow',
  requireAuth,
  asyncRoute(async (req, res) => {
    const target = await getUserById(req.params.userId);
    if (!target || target.deleted_at) throw notFound('user_not_found', 'No such user');
    if (target.id === req.userId) throw badRequest('self_follow', 'You cannot follow yourself');
    if (await blockedEither(req.userId, target.id)) throw forbidden('blocked', 'Not allowed');
    await query('insert into follows (follower_id, following_id) values ($1, $2) on conflict do nothing', [
      req.userId,
      target.id,
    ]);
    sendToUser(target.id, { type: 'follow:new', userId: req.userId });
    res.json({ following: true });
  }),
);

router.delete(
  '/users/:userId/follow',
  requireAuth,
  asyncRoute(async (req, res) => {
    await query('delete from follows where follower_id = $1 and following_id = $2', [req.userId, req.params.userId]);
    res.json({ following: false });
  }),
);

async function followList(req, res, mode) {
  const limit = pageLimit(req.query.limit, 50, 100);
  const where = mode === 'followers' ? 'f.following_id = $1' : 'f.follower_id = $1';
  const joinOn = mode === 'followers' ? 'f.follower_id = u.id' : 'f.following_id = u.id';
  const { rows } = await query(
    `select u.*, f.created_at as followed_at,
            exists(select 1 from follows mine where mine.follower_id = $2 and mine.following_id = u.id) as i_follow
       from follows f join users u on ${joinOn}
      where ${where} and u.deleted_at is null
        and not exists (select 1 from blocks b
           where (b.blocker_id = $2 and b.blocked_id = u.id) or (b.blocker_id = u.id and b.blocked_id = $2))
      order by f.created_at desc limit $3`,
    [req.params.userId, req.userId, limit],
  );
  res.json({
    users: rows.map((row) => otherUser(row, { iFollow: row.i_follow, followedAt: row.followed_at, online: isOnline(row.id) })),
  });
}

router.get('/users/:userId/followers', requireAuth, asyncRoute((req, res) => followList(req, res, 'followers')));
router.get('/users/:userId/following', requireAuth, asyncRoute((req, res) => followList(req, res, 'following')));

/* ------------------------------------------------------------------ *
 * Blocks
 * ------------------------------------------------------------------ */

router.post(
  '/blocks/:userId',
  requireAuth,
  asyncRoute(async (req, res) => {
    if (req.params.userId === req.userId) throw badRequest('self_block', 'You cannot block yourself');
    const target = await getUserById(req.params.userId);
    if (!target) throw notFound('user_not_found', 'No such user');
    await query('insert into blocks (blocker_id, blocked_id) values ($1, $2) on conflict do nothing', [
      req.userId,
      target.id,
    ]);
    // Blocking severs the social graph and pending requests.
    await removeFriendship(req.userId, target.id);
    await query(
      `update friend_requests set status = 'cancelled'
        where status = 'pending' and ((from_user_id = $1 and to_user_id = $2) or (from_user_id = $2 and to_user_id = $1))`,
      [req.userId, target.id],
    );
    await query('delete from follows where (follower_id = $1 and following_id = $2) or (follower_id = $2 and following_id = $1)', [
      req.userId,
      target.id,
    ]);
    res.json({ blocked: true });
  }),
);

router.delete(
  '/blocks/:userId',
  requireAuth,
  asyncRoute(async (req, res) => {
    await query('delete from blocks where blocker_id = $1 and blocked_id = $2', [req.userId, req.params.userId]);
    res.json({ blocked: false });
  }),
);

router.get(
  '/blocks',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select u.*, b.created_at as blocked_at from blocks b join users u on u.id = b.blocked_id
        where b.blocker_id = $1 order by b.created_at desc`,
      [req.userId],
    );
    res.json({ users: rows.map((row) => otherUser(row, { blockedAt: row.blocked_at })) });
  }),
);

/* ------------------------------------------------------------------ *
 * Devices (push tokens)
 * ------------------------------------------------------------------ */

router.post(
  '/devices',
  requireAuth,
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        fcmToken: z.string().min(10).max(4096),
        platform: z.string().max(20).optional(),
        appVersion: z.string().max(40).optional(),
      })
      .parse(req.body);
    await query(
      `insert into devices (id, user_id, fcm_token, platform, app_version)
       values ($1, $2, $3, $4, $5)
       on conflict (fcm_token) do update
         set user_id = excluded.user_id, platform = excluded.platform,
             app_version = excluded.app_version, updated_at = now(), last_seen_at = now()`,
      [uuid(), req.userId, body.fcmToken, body.platform || 'android', body.appVersion || null],
    );
    res.json({ status: 'registered' });
  }),
);

router.delete(
  '/devices',
  requireAuth,
  asyncRoute(async (req, res) => {
    const token = String(req.query.fcmToken || req.body?.fcmToken || '');
    if (token) await query('delete from devices where fcm_token = $1 and user_id = $2', [token, req.userId]);
    else await query('delete from devices where user_id = $1', [req.userId]);
    res.json({ status: 'removed' });
  }),
);

/* ------------------------------------------------------------------ *
 * Notifications
 * ------------------------------------------------------------------ */

router.get(
  '/notifications',
  requireAuth,
  asyncRoute(async (req, res) => {
    const limit = pageLimit(req.query.limit, 30, 100);
    const cursor = decodeCursor(req.query.cursor);
    const { rows } = await query(
      `select n.*, u.username as actor_username, u.display_name as actor_name, u.avatar_media_id as actor_avatar
         from notifications n left join users u on u.id = n.actor_id
        where n.user_id = $1
          and ($2::timestamptz is null or (n.created_at, n.id) < ($2::timestamptz, $3::uuid))
        order by n.created_at desc, n.id desc limit $4`,
      [req.userId, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );
    const page = rows.slice(0, limit);
    res.json({
      notifications: page.map((row) => ({
        id: row.id,
        kind: row.kind,
        data: row.data,
        read: Boolean(row.read_at),
        createdAt: row.created_at,
        actor: row.actor_username
          ? {
              id: row.actor_id,
              username: row.actor_username,
              displayName: row.actor_name,
              avatarUrl: row.actor_avatar ? signedMediaUrl(row.actor_avatar) : null,
            }
          : null,
      })),
      nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1].created_at, page[page.length - 1].id) : null,
    });
  }),
);

router.post(
  '/notifications/read',
  requireAuth,
  asyncRoute(async (req, res) => {
    const ids = Array.isArray(req.body?.ids) ? req.body.ids.filter((x) => typeof x === 'string') : null;
    if (ids?.length) {
      await query('update notifications set read_at = now() where user_id = $1 and id = any($2::uuid[])', [
        req.userId,
        ids,
      ]);
    } else {
      await query('update notifications set read_at = now() where user_id = $1 and read_at is null', [req.userId]);
    }
    res.json({ status: 'ok' });
  }),
);

/* ------------------------------------------------------------------ *
 * Account deletion (GDPR-style: immediate disable, purge after 30 days)
 * ------------------------------------------------------------------ */

router.delete(
  '/users/me',
  requireAuth,
  asyncRoute(async (req, res) => {
    const body = z
      .object({ password: z.string().max(200).optional(), confirm: z.literal('DELETE') })
      .parse(req.body ?? {});
    const user = await getUserById(req.userId);
    if (!user) throw unauthorized();
    if (user.password_hash) {
      if (!body.password) throw badRequest('password_required', 'Enter your password to delete your account.');
      const ok = await verifyPassword(body.password, user.password_hash);
      if (!ok) throw unauthorized('invalid_credentials', 'Password is incorrect.');
    }
    const { rows } = await query(
      `update users set deleted_at = now(), updated_at = now(),
              username = null, google_sub = null, avatar_media_id = null, bio = '', display_name = 'Deleted user'
        where id = $1 returning username`,
      [req.userId],
    );
    if (user.username) {
      await query('insert into username_history (username, user_id, released_at) values ($1, $2, now())', [
        user.username,
        req.userId,
      ]);
    }
    await query('delete from devices where user_id = $1', [req.userId]);
    await query('delete from conversation_members where user_id = $1', [req.userId]);
    await revokeAllSessions(req.userId);
    sendToUser(req.userId, { type: 'account:deleted' });
    res.json({
      status: 'deleted',
      purgedUsername: rows[0]?.username || null,
      message: 'Your account is deactivated. Data is purged after 30 days.',
    });
  }),
);

export default router;
