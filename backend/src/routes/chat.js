import express from 'express';
import { z } from 'zod';
import { query, withTransaction } from '../db.js';
import { asyncRoute, badRequest, forbidden, notFound } from '../errors.js';
import { requireAuth, requireOnboarded } from '../auth.js';
import { rateLimit } from '../ratelimit.js';
import { areFriends, blockedEither, ensureDirectConversation } from '../friends.js';
import { getUserById, otherUser } from '../service.js';
import { decodeCursor, encodeCursor, pageLimit, uuid } from '../util.js';
import { serializeMedia, serializeMessage } from '../serialize.js';
import { broadcastMessage, isOnline, markConversationRead, sendToUser } from '../realtime.js';

const router = express.Router();

const MESSAGE_PREVIEW = {
  text: (body) => (body || '').slice(0, 120),
  image: () => 'Photo',
  video: () => 'Video',
  audio: () => 'Voice message',
  file: () => 'File',
  call: () => 'Call',
  system: () => 'Message',
};

async function membership(userId, conversationId) {
  const { rows } = await query(
    `select * from conversation_members where conversation_id = $1 and user_id = $2 and left_at is null`,
    [conversationId, userId],
  );
  return rows[0] || null;
}

async function requireMember(userId, conversationId) {
  const member = await membership(userId, conversationId);
  if (!member) throw notFound('conversation_not_found', 'Conversation not found');
  return member;
}

/* ------------------------------------------------------------------ *
 * Conversations
 * ------------------------------------------------------------------ */

router.get(
  '/conversations',
  requireAuth,
  asyncRoute(async (req, res) => {
    const limit = pageLimit(req.query.limit, 30, 60);
    const cursor = decodeCursor(req.query.cursor);
    const { rows } = await query(
      `select c.*,
              cm.last_read_at,
              cm.muted,
              lm.id as last_message_id, lm.body as last_body, lm.kind as last_kind,
              lm.created_at as last_created_at, lm.sender_id as last_sender_id, lm.deleted_at as last_deleted_at,
              peer.id as peer_id, peer.username as peer_username, peer.display_name as peer_name,
              peer.avatar_media_id as peer_avatar, peer.last_seen_at as peer_last_seen
         from conversation_members cm
         join conversations c on c.id = cm.conversation_id
         left join lateral (
           select * from messages m
            where m.conversation_id = c.id and m.deleted_at is null
            order by m.created_at desc, m.id desc limit 1
         ) lm on true
         left join lateral (
           select u.* from conversation_members cm2 join users u on u.id = cm2.user_id
            where cm2.conversation_id = c.id and cm2.user_id <> $1 limit 1
         ) peer on true
        where cm.user_id = $1 and cm.left_at is null
          and ($2::timestamptz is null or (c.last_message_at, c.id) < ($2::timestamptz, $3::uuid))
        order by c.last_message_at desc, c.id desc
        limit $4`,
      [req.userId, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );

    const page = rows.slice(0, limit);
    const ids = page.map((r) => r.id);
    const unread = ids.length
      ? (
          await query(
            `select m.conversation_id, count(*)::int as unread
               from messages m
               join conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = $1
              where m.conversation_id = any($2::uuid[]) and m.sender_id <> $1
                and m.deleted_at is null
                and not exists (
                  select 1 from message_receipts r
                   where r.message_id = m.id and r.user_id = $1 and r.read_at is not null
                )
              group by m.conversation_id`,
            [req.userId, ids],
          )
        ).rows
      : [];
    const unreadMap = Object.fromEntries(unread.map((r) => [r.conversation_id, r.unread]));

    res.json({
      conversations: page.map((row) => ({
        id: row.id,
        kind: row.kind,
        muted: row.muted,
        createdAt: row.created_at,
        lastMessageAt: row.last_message_at,
        unreadCount: unreadMap[row.id] || 0,
        peer: row.peer_id
          ? otherUser(
              {
                id: row.peer_id,
                username: row.peer_username,
                display_name: row.peer_name,
                avatar_media_id: row.peer_avatar,
                last_seen_at: row.peer_last_seen,
              },
              { online: isOnline(row.peer_id) },
            )
          : null,
        lastMessage: row.last_message_id
          ? {
              id: row.last_message_id,
              kind: row.last_kind,
              body: row.last_deleted_at ? null : row.last_body,
              senderId: row.last_sender_id,
              createdAt: row.last_created_at,
              deleted: Boolean(row.last_deleted_at),
            }
          : null,
      })),
      nextCursor: rows.length > limit ? encodeCursor(page[page.length - 1].last_message_at, page[page.length - 1].id) : null,
    });
  }),
);

router.post(
  '/conversations',
  requireAuth,
  requireOnboarded,
  asyncRoute(async (req, res) => {
    const body = z.object({ userId: z.string().uuid().optional(), username: z.string().max(30).optional() }).parse(req.body);
    let targetId = body.userId || null;
    if (!targetId && body.username) {
      const { rows } = await query('select id from users where username = $1', [body.username.replace(/^@/, '').toLowerCase()]);
      targetId = rows[0]?.id || null;
    }
    if (!targetId) throw badRequest('missing_target', 'Provide userId or username');
    if (targetId === req.userId) throw badRequest('self_conversation', 'You cannot chat with yourself');

    const target = await getUserById(targetId);
    if (!target || target.deleted_at) throw notFound('user_not_found', 'No such user');
    if (await blockedEither(req.userId, targetId)) throw forbidden('blocked', 'Not allowed');

    const pairKey = [req.userId, targetId].sort().join(':');
    const existing = await query('select id from conversations where pair_key = $1', [pairKey]);
    if (!existing.rows[0] && !(await areFriends(req.userId, targetId))) {
      throw forbidden('not_friends', 'Become friends first to start a chat.');
    }
    const conversationId = await ensureDirectConversation(req.userId, targetId);
    res.status(201).json({ conversationId });
  }),
);

router.get(
  '/conversations/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    await requireMember(req.userId, req.params.id);
    const { rows } = await query(
      `select u.* from conversation_members cm join users u on u.id = cm.user_id
        where cm.conversation_id = $1 and cm.user_id <> $2`,
      [req.params.id, req.userId],
    );
    res.json({
      conversation: {
        id: req.params.id,
        members: rows.map((row) => otherUser(row, { online: isOnline(row.id) })),
      },
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Messages
 * ------------------------------------------------------------------ */

router.get(
  '/conversations/:id/messages',
  requireAuth,
  asyncRoute(async (req, res) => {
    await requireMember(req.userId, req.params.id);
    const limit = pageLimit(req.query.limit, 30, 100);
    const cursor = decodeCursor(req.query.cursor);
    const { rows } = await query(
      `select m.*, md.kind as media_kind, md.mime as media_mime, md.bytes as media_bytes,
              md.width as media_width, md.height as media_height, md.duration_ms as media_duration,
              md.storage_key as media_storage_key, md.thumb_key as media_thumb_key,
              md.original_name as media_original_name, md.created_at as media_created_at,
              r.delivered_at as my_delivered_at, r.read_at as my_read_at
         from messages m
         left join media md on md.id = m.media_id
         left join message_receipts r on r.message_id = m.id and r.user_id = $2
        where m.conversation_id = $1
          and ($3::timestamptz is null or (m.created_at, m.id) < ($3::timestamptz, $4::uuid))
        order by m.created_at desc, m.id desc
        limit $5`,
      [req.params.id, req.userId, cursor?.createdAt || null, cursor?.id || null, limit + 1],
    );
    const page = rows.slice(0, limit);
    const hasMore = rows.length > limit;

    // Fetching a conversation implies delivery of everything in the page.
    const incomingIds = page.filter((r) => r.sender_id !== req.userId).map((r) => r.id);
    if (incomingIds.length) {
      await query(
        `insert into message_receipts (message_id, user_id, delivered_at)
         select unnest($1::uuid[]), $2, now()
         on conflict (message_id, user_id) do update set delivered_at = coalesce(message_receipts.delivered_at, now())`,
        [incomingIds, req.userId],
      );
      await query('update messages set delivered_at = coalesce(delivered_at, now()) where id = any($1::uuid[])', [
        incomingIds,
      ]);
      const senders = [...new Set(page.filter((r) => r.sender_id !== req.userId).map((r) => r.sender_id))];
      for (const senderId of senders) {
        sendToUser(senderId, {
          type: 'message:status',
          conversationId: req.params.id,
          messageIds: incomingIds,
          status: 'delivered',
          at: new Date().toISOString(),
        });
      }
    }

    res.json({
      messages: page
        .map((row) =>
          serializeMessage(row, {
            media: row.media_id
              ? {
                  id: row.media_id,
                  kind: row.media_kind,
                  mime: row.media_mime,
                  bytes: row.media_bytes,
                  width: row.media_width,
                  height: row.media_height,
                  duration_ms: row.media_duration,
                  storage_key: row.media_storage_key,
                  thumb_key: row.media_thumb_key,
                  original_name: row.media_original_name,
                  created_at: row.media_created_at,
                }
              : null,
          }),
        )
        .reverse(),
      nextCursor: hasMore ? encodeCursor(page[page.length - 1].created_at, page[page.length - 1].id) : null,
      hasMore,
    });
  }),
);

router.post(
  '/conversations/:id/messages',
  requireAuth,
  requireOnboarded,
  rateLimit({ limit: 240, windowMs: 60 * 1000, keyPrefix: 'send' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        clientId: z.string().min(6).max(120),
        kind: z.enum(['text', 'image', 'video', 'audio', 'file', 'call']).default('text'),
        body: z.string().max(4000).optional(),
        mediaId: z.string().uuid().optional(),
        replyToId: z.string().uuid().optional(),
        createdAt: z.string().datetime().optional(),
      })
      .parse(req.body);

    const conversationId = req.params.id;
    await requireMember(req.userId, conversationId);

    // Blocked peers cannot reach each other, in either direction.
    const { rows: others } = await query(
      'select user_id from conversation_members where conversation_id = $1 and user_id <> $2',
      [conversationId, req.userId],
    );
    for (const other of others) {
      if (await blockedEither(req.userId, other.user_id)) throw forbidden('blocked', 'You cannot message this person.');
    }

    if (body.kind === 'text' && !body.body?.trim()) throw badRequest('empty_message', 'Message text is empty');
    if (['image', 'video', 'audio', 'file'].includes(body.kind) && !body.mediaId) {
      throw badRequest('missing_media', 'Attach a file first');
    }
    if (body.mediaId) {
      const { rows: mediaRows } = await query('select owner_id from media where id = $1 and deleted_at is null', [
        body.mediaId,
      ]);
      if (!mediaRows[0] || mediaRows[0].owner_id !== req.userId) throw badRequest('invalid_media', 'Unknown media');
    }

    // Idempotent insert: the unique (conversation, sender, clientId) index makes
    // a duplicate tap or an offline replay return the original message.
    const messageId = uuid();
    const inserted = await query(
      `insert into messages (id, conversation_id, sender_id, client_id, kind, body, media_id, reply_to_id)
       values ($1, $2, $3, $4, $5, $6, $7, $8)
       on conflict (conversation_id, sender_id, client_id) do nothing
       returning *`,
      [
        messageId,
        conversationId,
        req.userId,
        body.clientId,
        body.kind,
        body.body ?? null,
        body.mediaId ?? null,
        body.replyToId ?? null,
      ],
    );

    if (!inserted.rows[0]) {
      const { rows } = await query(
        'select * from messages where conversation_id = $1 and sender_id = $2 and client_id = $3',
        [conversationId, req.userId, body.clientId],
      );
      const existing = rows[0];
      const mediaRows = existing?.media_id
        ? (await query('select * from media where id = $1', [existing.media_id])).rows[0]
        : null;
      return res.status(200).json({
        deduplicated: true,
        message: serializeMessage(existing, { media: mediaRows || null }),
      });
    }

    const message = inserted.rows[0];
    await query('update conversations set last_message_at = $2 where id = $1', [conversationId, message.created_at]);

    const mediaRows = message.media_id
      ? (await query('select * from media where id = $1', [message.media_id])).rows[0]
      : null;
    const me = await getUserById(req.userId);
    const preview = MESSAGE_PREVIEW[message.kind]?.(message.body) || 'New message';
    await broadcastMessage(
      { ...message, media: mediaRows || null },
      { senderId: req.userId, conversationId, senderName: me.display_name || me.username, preview },
    );

    // Receipts can arrive over the socket before this response; return the
    // latest status rather than overwriting 'delivered' with stale 'sent'.
    const latest = (await query('select * from messages where id = $1', [message.id])).rows[0];
    res.status(201).json({ message: serializeMessage(latest, { media: mediaRows || null }) });
  }),
);

router.post(
  '/conversations/:id/read',
  requireAuth,
  asyncRoute(async (req, res) => {
    const body = z.object({ messageId: z.string().uuid().optional() }).parse(req.body ?? {});
    await requireMember(req.userId, req.params.id);
    const result = await markConversationRead(req.userId, req.params.id, body.messageId);
    res.json({ status: 'read', updated: result.updated });
  }),
);

router.post(
  '/messages/delivered',
  requireAuth,
  asyncRoute(async (req, res) => {
    const body = z.object({ messageIds: z.array(z.string().uuid()).max(200) }).parse(req.body);
    const { rows } = await query(
      `select m.id, m.sender_id, m.conversation_id
         from messages m
         join conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = $1 and cm.left_at is null
        where m.id = any($2::uuid[]) and m.sender_id <> $1`,
      [req.userId, body.messageIds],
    );
    for (const row of rows) {
      await query(
        `insert into message_receipts (message_id, user_id, delivered_at) values ($1, $2, now())
         on conflict (message_id, user_id) do update set delivered_at = coalesce(message_receipts.delivered_at, now())`,
        [row.id, req.userId],
      );
    }
    if (rows.length) {
      await query('update messages set delivered_at = coalesce(delivered_at, now()) where id = any($1::uuid[])', [
        rows.map((r) => r.id),
      ]);
      for (const senderId of [...new Set(rows.map((r) => r.sender_id))]) {
        sendToUser(senderId, {
          type: 'message:status',
          conversationId: rows.find((r) => r.sender_id === senderId).conversation_id,
          messageIds: rows.filter((r) => r.sender_id === senderId).map((r) => r.id),
          status: 'delivered',
          at: new Date().toISOString(),
        });
      }
    }
    res.json({ status: 'ok', updated: rows.length });
  }),
);

router.delete(
  '/messages/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query('select * from messages where id = $1 and sender_id = $2', [
      req.params.id,
      req.userId,
    ]);
    const message = rows[0];
    if (!message) throw notFound('message_not_found', 'Message not found');
    await withTransaction(async (client) => {
      await client.query('update messages set deleted_at = now(), body = null where id = $1', [message.id]);
      if (message.media_id) await client.query('delete from media where id = $1', [message.media_id]);
    });
    const { rows: members } = await query('select user_id from conversation_members where conversation_id = $1', [
      message.conversation_id,
    ]);
    for (const member of members) {
      sendToUser(member.user_id, {
        type: 'message:deleted',
        conversationId: message.conversation_id,
        messageId: message.id,
      });
    }
    res.json({ status: 'deleted' });
  }),
);

/* ------------------------------------------------------------------ *
 * Call history
 * ------------------------------------------------------------------ */

// A callee who tapped an Android notification can recover the offer while it
// is still ringing; callers and third parties cannot fetch this endpoint.
router.get('/calls/:id/incoming', requireAuth, asyncRoute(async (req, res) => {
  const { rows } = await query(
    `select c.*, u.username, u.display_name, u.avatar_media_id from calls c
       join users u on u.id = c.caller_id
      where c.id = $1 and c.callee_id = $2 and c.status = 'ringing'
        and c.created_at > now() - interval '90 seconds' and u.deleted_at is null`,
    [req.params.id, req.userId],
  );
  const call = rows[0];
  if (!call || await blockedEither(req.userId, call.caller_id)) throw notFound('call_not_found', 'This call has ended.');
  const candidates = await query(
    'select candidate from call_ice_candidates where call_id = $1 and from_user_id = $2 order by id',
    [call.id, call.caller_id],
  );
  res.json({
    type: 'call:incoming', callId: call.id, conversationId: call.conversation_id,
    kind: call.kind, sdp: call.offer, from: otherUser({ id: call.caller_id, username: call.username,
      display_name: call.display_name, avatar_media_id: call.avatar_media_id }),
    candidates: candidates.rows.map((r) => r.candidate),
  });
}));

router.get(
  '/calls',
  requireAuth,
  asyncRoute(async (req, res) => {
    const limit = pageLimit(req.query.limit, 30, 100);
    const { rows } = await query(
      `select c.*,
              caller.username as caller_username, caller.display_name as caller_name,
              callee.username as callee_username, callee.display_name as callee_name
         from calls c
         join users caller on caller.id = c.caller_id
         join users callee on callee.id = c.callee_id
        where c.caller_id = $1 or c.callee_id = $1
        order by c.created_at desc limit $2`,
      [req.userId, limit],
    );
    res.json({
      calls: rows.map((row) => ({
        id: row.id,
        conversationId: row.conversation_id,
        kind: row.kind,
        status: row.status,
        direction: row.caller_id === req.userId ? 'outgoing' : 'incoming',
        peer: row.caller_id === req.userId
          ? { id: row.callee_id, username: row.callee_username, displayName: row.callee_name }
          : { id: row.caller_id, username: row.caller_username, displayName: row.caller_name },
        createdAt: row.created_at,
        answeredAt: row.answered_at,
        endedAt: row.ended_at,
      })),
    });
  }),
);

export default router;
