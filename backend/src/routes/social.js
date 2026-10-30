import express from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { asyncRoute, badRequest, forbidden, notFound } from '../errors.js';
import { requireAuth, requireOnboarded } from '../auth.js';
import { rateLimit } from '../ratelimit.js';
import { areFriends, blockedEither } from '../friends.js';
import { otherUser } from '../service.js';
import { decodeCursor, encodeCursor, pageLimit, uuid } from '../util.js';
import { serializeMedia } from '../serialize.js';
import { sendToUser } from '../realtime.js';
import { sendPushToUser } from '../push.js';

const router = express.Router();

const postColumns = `p.*, u.username, u.display_name, u.avatar_media_id, u.last_seen_at,
  md.id as m_id, md.kind as m_kind, md.mime as m_mime, md.bytes as m_bytes, md.width as m_width,
  md.height as m_height, md.duration_ms as m_duration, md.original_name as m_name, md.created_at as m_created_at,
  (select count(*)::int from post_likes pl where pl.post_id = p.id) as like_count,
  (select count(*)::int from comments c where c.post_id = p.id and c.deleted_at is null) as comment_count,
  exists(select 1 from post_likes pl where pl.post_id = p.id and pl.user_id = $1) as liked_by_me`;

function shapePost(row) {
  return {
    id: row.id,
    body: row.body,
    visibility: row.visibility,
    createdAt: row.created_at,
    author: otherUser({
      id: row.user_id,
      username: row.username,
      display_name: row.display_name,
      avatar_media_id: row.avatar_media_id,
      last_seen_at: row.last_seen_at,
    }),
    media: row.m_id
      ? serializeMedia({
          id: row.m_id,
          kind: row.m_kind,
          mime: row.m_mime,
          bytes: row.m_bytes,
          width: row.m_width,
          height: row.m_height,
          duration_ms: row.m_duration,
          original_name: row.m_name,
          created_at: row.m_created_at,
        })
      : null,
    likeCount: row.like_count ?? 0,
    commentCount: row.comment_count ?? 0,
    likedByMe: Boolean(row.liked_by_me),
  };
}

async function requireVisiblePost(postId, viewerId) {
  const { rows } = await query('select id, user_id, visibility from posts where id = $1 and deleted_at is null', [postId]);
  const post = rows[0];
  if (!post) throw notFound('post_not_found', 'Post not found');
  if (post.user_id === viewerId) return post;
  if (await blockedEither(viewerId, post.user_id)) throw notFound('post_not_found', 'Post not found');
  if (post.visibility === 'private' || (post.visibility === 'friends' && !(await areFriends(viewerId, post.user_id)))) {
    throw forbidden('post_forbidden', 'Not allowed');
  }
  return post;
}

async function socialNotification(userId, actorId, kind, postId) {
  await query(
    `insert into notifications (id, user_id, kind, actor_id, entity_type, entity_id, data)
     values ($1, $2, $3, $4, 'post', $5, $6)`,
    [uuid(), userId, kind, actorId, postId, JSON.stringify({ postId })],
  );
}

/* ------------------------------------------------------------------ *
 * Feed & posts
 * ------------------------------------------------------------------ */

router.get(
  '/feed',
  requireAuth,
  asyncRoute(async (req, res) => {
    const limit = pageLimit(req.query.limit, 15, 40);
    const cursor = decodeCursor(req.query.cursor);
    const { rows } = await query(
      `select ${postColumns}
         from posts p
         join users u on u.id = p.user_id
         left join media md on md.id = p.media_id
        where p.deleted_at is null and u.deleted_at is null
          and (
            p.user_id = $1
            or (p.visibility = 'friends' and exists (
                 select 1 from friendships f
                  where f.user_a = least(p.user_id, $1::uuid) and f.user_b = greatest(p.user_id, $1::uuid)))
            or (p.visibility = 'public' and exists (
                 select 1 from follows fo where fo.follower_id = $1 and fo.following_id = p.user_id))
          )
          and not exists (select 1 from blocks b
                where (b.blocker_id = $1 and b.blocked_id = p.user_id) or (b.blocker_id = p.user_id and b.blocked_id = $1))
          and ($2::timestamptz is null or (p.created_at, p.id) < ($2::timestamptz, $3::uuid))
        order by p.created_at desc, p.id desc
        limit $4`,
      [req.userId, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );
    const page = rows.slice(0, limit);
    res.json({
      posts: page.map(shapePost),
      nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1].created_at, page[page.length - 1].id) : null,
    });
  }),
);

router.post(
  '/posts',
  requireAuth,
  requireOnboarded,
  rateLimit({ limit: 30, windowMs: 60 * 60 * 1000, keyPrefix: 'post' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        body: z.string().max(2000).optional(),
        mediaId: z.string().uuid().optional(),
        visibility: z.enum(['public', 'friends', 'private']).optional(),
      })
      .parse(req.body ?? {});
    if (!body.body?.trim() && !body.mediaId) throw badRequest('empty_post', 'Write something or add a photo');
    if (body.mediaId) {
      const { rows } = await query('select owner_id from media where id = $1 and deleted_at is null', [body.mediaId]);
      if (!rows[0] || rows[0].owner_id !== req.userId) throw badRequest('invalid_media', 'Unknown media');
    }
    const id = uuid();
    await query(
      `insert into posts (id, user_id, body, media_id, visibility) values ($1,$2,$3,$4,$5)`,
      [id, req.userId, body.body || '', body.mediaId || null, body.visibility || 'friends'],
    );
    const { rows } = await query(
      `select ${postColumns} from posts p join users u on u.id = p.user_id
        left join media md on md.id = p.media_id where p.id = $2`,
      [req.userId, id],
    );
    res.status(201).json({ post: shapePost(rows[0]) });
  }),
);

router.get(
  '/posts/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select ${postColumns} from posts p join users u on u.id = p.user_id
        left join media md on md.id = p.media_id where p.id = $2 and p.deleted_at is null`,
      [req.userId, req.params.id],
    );
    const row = rows[0];
    if (!row) throw notFound('post_not_found', 'Post not found');
    await requireVisiblePost(req.params.id, req.userId);
    res.json({ post: shapePost(row) });
  }),
);

router.delete(
  '/posts/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rowCount } = await query('update posts set deleted_at = now() where id = $1 and user_id = $2', [
      req.params.id,
      req.userId,
    ]);
    if (!rowCount) throw notFound('post_not_found', 'Post not found');
    res.json({ status: 'deleted' });
  }),
);

router.get(
  '/users/:username/posts',
  requireAuth,
  asyncRoute(async (req, res) => {
    const username = String(req.params.username).replace(/^@/, '').toLowerCase();
    const { rows: userRows } = await query('select id from users where username = $1 and deleted_at is null', [username]);
    if (!userRows[0]) throw notFound('user_not_found', 'No such user');
    const targetId = userRows[0].id;
    if (await blockedEither(req.userId, targetId)) throw notFound('user_not_found', 'No such user');
    const isMe = targetId === req.userId;
    const friends = isMe || (await areFriends(req.userId, targetId));
    const limit = pageLimit(req.query.limit, 15, 40);
    const cursor = decodeCursor(req.query.cursor);
    const { rows } = await query(
      `select ${postColumns} from posts p join users u on u.id = p.user_id
        left join media md on md.id = p.media_id
        where p.deleted_at is null and p.user_id = $2
          and ($3::boolean or p.visibility = 'public' or ($4::boolean and p.visibility = 'friends'))
          and ($5::timestamptz is null or (p.created_at, p.id) < ($5::timestamptz, $6::uuid))
        order by p.created_at desc, p.id desc limit $7`,
      [req.userId, targetId, isMe, friends, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );
    const page = rows.slice(0, limit);
    res.json({
      posts: page.map(shapePost),
      nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1].created_at, page[page.length - 1].id) : null,
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Likes
 * ------------------------------------------------------------------ */

router.post(
  '/posts/:id/like',
  requireAuth,
  asyncRoute(async (req, res) => {
    const post = await requireVisiblePost(req.params.id, req.userId);
    const inserted = await query('insert into post_likes (post_id, user_id) values ($1, $2) on conflict do nothing', [
      req.params.id,
      req.userId,
    ]);
    const { rows } = await query('select count(*)::int as n from post_likes where post_id = $1', [req.params.id]);
    const authorId = post.user_id;
    if (authorId !== req.userId && inserted.rowCount) {
      await socialNotification(authorId, req.userId, 'like', req.params.id);
      sendToUser(authorId, { type: 'post:liked', postId: req.params.id, userId: req.userId, likeCount: rows[0].n });
      const { rows: meRows } = await query('select display_name, username from users where id = $1', [req.userId]);
      sendPushToUser(authorId, {
        title: 'New like',
        body: `${meRows[0]?.display_name || meRows[0]?.username || 'Someone'} liked your post`,
        data: { type: 'post_like', postId: req.params.id },
        channelId: 'social',
      }).catch(() => {});
    }
    res.json({ liked: true, likeCount: rows[0].n });
  }),
);

router.delete(
  '/posts/:id/like',
  requireAuth,
  asyncRoute(async (req, res) => {
    await requireVisiblePost(req.params.id, req.userId);
    await query('delete from post_likes where post_id = $1 and user_id = $2', [req.params.id, req.userId]);
    const { rows } = await query('select count(*)::int as n from post_likes where post_id = $1', [req.params.id]);
    res.json({ liked: false, likeCount: rows[0].n });
  }),
);

/* ------------------------------------------------------------------ *
 * Comments
 * ------------------------------------------------------------------ */

router.get(
  '/posts/:id/comments',
  requireAuth,
  asyncRoute(async (req, res) => {
    await requireVisiblePost(req.params.id, req.userId);
    const limit = pageLimit(req.query.limit, 20, 50);
    const cursor = decodeCursor(req.query.cursor);
    const { rows } = await query(
      `select c.*, u.username, u.display_name, u.avatar_media_id, u.last_seen_at
         from comments c join users u on u.id = c.user_id
        where c.post_id = $1 and c.deleted_at is null
          and ($2::timestamptz is null or (c.created_at, c.id) < ($2::timestamptz, $3::uuid))
        order by c.created_at desc, c.id desc limit $4`,
      [req.params.id, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );
    const page = rows.slice(0, limit);
    res.json({
      comments: page
        .map((row) => ({
          id: row.id,
          body: row.body,
          parentId: row.parent_id,
          createdAt: row.created_at,
          isMine: row.user_id === req.userId,
          author: otherUser(row),
        }))
        .reverse(),
      nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1].created_at, page[page.length - 1].id) : null,
    });
  }),
);

router.post(
  '/posts/:id/comments',
  requireAuth,
  requireOnboarded,
  rateLimit({ limit: 60, windowMs: 60 * 60 * 1000, keyPrefix: 'comment' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({ body: z.string().trim().min(1).max(1000), parentId: z.string().uuid().optional() })
      .parse(req.body);
    const post = await requireVisiblePost(req.params.id, req.userId);
    if (body.parentId) {
      const parent = await query('select 1 from comments where id = $1 and post_id = $2 and deleted_at is null', [body.parentId, req.params.id]);
      if (!parent.rows.length) throw badRequest('invalid_parent', 'That comment is not part of this post.');
    }
    const id = uuid();
    await query('insert into comments (id, post_id, user_id, body, parent_id) values ($1,$2,$3,$4,$5)', [
      id,
      req.params.id,
      req.userId,
      body.body,
      body.parentId || null,
    ]);
    const { rows } = await query(
      'select c.*, u.username, u.display_name, u.avatar_media_id, u.last_seen_at from comments c join users u on u.id = c.user_id where c.id = $1',
      [id],
    );
    const authorId = post.user_id;
    if (authorId !== req.userId) {
      await socialNotification(authorId, req.userId, 'comment', req.params.id);
      sendToUser(authorId, { type: 'post:commented', postId: req.params.id, userId: req.userId });
      sendPushToUser(authorId, {
        title: 'New comment',
        body: `${rows[0].display_name || rows[0].username}: ${body.body.slice(0, 80)}`,
        data: { type: 'comment', postId: req.params.id },
        channelId: 'social',
      }).catch(() => {});
    }
    res.status(201).json({
      comment: {
        id,
        body: rows[0].body,
        parentId: rows[0].parent_id,
        createdAt: rows[0].created_at,
        isMine: true,
        author: otherUser(rows[0]),
      },
    });
  }),
);

router.delete(
  '/comments/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select c.*, p.user_id as post_author from comments c join posts p on p.id = c.post_id where c.id = $1`,
      [req.params.id],
    );
    const comment = rows[0];
    if (!comment) throw notFound('comment_not_found', 'Comment not found');
    if (comment.user_id !== req.userId && comment.post_author !== req.userId) {
      throw forbidden('not_allowed', 'You can only delete your own comments');
    }
    await query('update comments set deleted_at = now() where id = $1', [req.params.id]);
    res.json({ status: 'deleted' });
  }),
);

/* ------------------------------------------------------------------ *
 * Reports
 * ------------------------------------------------------------------ */

router.post(
  '/reports',
  requireAuth,
  rateLimit({ limit: 20, windowMs: 60 * 60 * 1000, keyPrefix: 'report' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        targetType: z.enum(['user', 'post', 'comment', 'message', 'story']),
        targetId: z.string().uuid(),
        reason: z.enum([
          'spam',
          'harassment',
          'hate_speech',
          'nudity',
          'violence',
          'impersonation',
          'scam',
          'other',
        ]),
        details: z.string().max(1000).optional(),
      })
      .parse(req.body);
    const id = uuid();
    await query(
      `insert into reports (id, reporter_id, target_type, target_id, reason, details) values ($1,$2,$3,$4,$5,$6)`,
      [id, req.userId, body.targetType, body.targetId, body.reason, body.details || null],
    );
    res.status(201).json({ id, status: 'open', message: 'Thanks - our team will review this.' });
  }),
);

export default router;
