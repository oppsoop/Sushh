import { WebSocketServer } from 'ws';
import { env } from './env.js';
import { query } from './db.js';
import { verifyAccessToken } from './auth.js';
import { sendPushToUser } from './push.js';
import { serializeMessage } from './serialize.js';
import { signedMediaUrl } from './storage.js';
import { areFriends } from './friends.js';

/**
 * Realtime hub.
 *
 * The WebSocket carries: incoming messages, typing indicators, delivery/read
 * receipts, presence and WebRTC call signalling. Sending a message goes
 * through the REST API (single, idempotent write path); the socket is the
 * fan-out channel.
 */
const connections = new Map(); // userId -> Set<WebSocket>
const socketMeta = new WeakMap(); // ws -> { userId, alive, subscriptions:Set }
let wss = null;

export function onlineUserIds() {
  return new Set([...connections.keys()]);
}

export function isOnline(userId) {
  return connections.has(userId);
}

export function connectionCount() {
  return [...connections.values()].reduce((n, set) => n + set.size, 0);
}

function send(ws, payload) {
  if (!ws || ws.readyState !== ws.OPEN) return false;
  try {
    ws.send(JSON.stringify(payload));
    return true;
  } catch {
    return false;
  }
}

export function sendToUser(userId, payload) {
  const sockets = connections.get(userId);
  if (!sockets) return 0;
  let sent = 0;
  for (const ws of sockets) {
    if (send(ws, payload)) sent += 1;
  }
  return sent;
}

export function disconnectUser(userId) {
  for (const socket of connections.get(userId) || []) {
    try { socket.close(4001, 'account unavailable'); } catch { /* already closed */ }
  }
}

export function sendToUsers(userIds, payload, { exceptUserId } = {}) {
  for (const id of userIds) {
    if (id === exceptUserId) continue;
    sendToUser(id, payload);
  }
}

async function conversationMemberIds(conversationId) {
  const { rows } = await query(
    'select user_id from conversation_members where conversation_id = $1 and left_at is null',
    [conversationId],
  );
  return rows.map((r) => r.user_id);
}

export async function sendToConversation(conversationId, payload, opts = {}) {
  const members = await conversationMemberIds(conversationId);
  sendToUsers(members, payload, opts);
  return members;
}

/** Fan a freshly stored message out to members + push to offline recipients. */
export async function broadcastMessage(messageRow, { senderName, senderId, conversationId, preview }) {
  const members = await conversationMemberIds(conversationId);
  const payload = {
    type: 'message:new',
    conversationId,
    message: { ...serializeMessage(messageRow, { media: messageRow.media ?? null }), status: 'sent' },
  };
  const delivered = [];
  for (const memberId of members) {
    if (memberId === senderId) continue;
    const count = sendToUser(memberId, payload);
    if (count > 0) delivered.push(memberId);
  }

  // Mark as delivered immediately for users that are connected right now.
  if (delivered.length) {
    await markDelivered(messageRow.id, delivered).catch(() => {});
    sendToUser(senderId, {
      type: 'message:status',
      conversationId,
      messageId: messageRow.id,
      status: 'delivered',
      at: new Date().toISOString(),
    });
  }

  // Push to members that are not connected.
  for (const memberId of members) {
    if (memberId === senderId || delivered.includes(memberId)) continue;
    sendPushToUser(memberId, {
      title: senderName,
      body: 'New message',
      data: { type: 'message', conversationId, messageId: messageRow.id, tag: `chat_${conversationId}` },
      channelId: 'messages',
    }).catch(() => {});
  }
  return members;
}

async function markDelivered(messageId, userIds) {
  for (const userId of userIds) {
    await query(
      `insert into message_receipts (message_id, user_id, delivered_at)
       values ($1, $2, now())
       on conflict (message_id, user_id) do update set delivered_at = coalesce(message_receipts.delivered_at, now())`,
      [messageId, userId],
    );
  }
  await query('update messages set delivered_at = coalesce(delivered_at, now()) where id = $1', [messageId]);
}

async function isMember(userId, conversationId) {
  const { rows } = await query(
    'select 1 from conversation_members where conversation_id = $1 and user_id = $2 and left_at is null',
    [conversationId, userId],
  );
  return rows.length > 0;
}

async function blockedBetween(a, b) {
  const { rows } = await query(
    `select 1 from blocks
      where (blocker_id = $1 and blocked_id = $2) or (blocker_id = $2 and blocked_id = $1) limit 1`,
    [a, b],
  );
  return rows.length > 0;
}

async function handleClientMessage(ws, meta, raw) {
  let msg;
  try {
    msg = JSON.parse(raw.toString());
  } catch {
    return send(ws, { type: 'error', code: 'bad_json', message: 'Could not parse message' });
  }
  const type = msg?.type;
  if (!type) return send(ws, { type: 'error', code: 'missing_type', message: 'Missing type' });

  // Touch presence on any activity.
  query('update users set last_seen_at = now() where id = $1', [meta.userId]).catch(() => {});

  switch (type) {
    case 'ping':
      return send(ws, { type: 'pong', at: Date.now() });

    case 'auth': {
      // Silent token refresh: the socket stays open while the access token rotates.
      try {
        const payload = verifyAccessToken(msg.token);
        if (payload.sub !== meta.userId) throw new Error('different account');
        meta.expiresAt = payload.exp * 1000;
        return send(ws, { type: 'auth:ok', userId: payload.sub });
      } catch {
        return send(ws, { type: 'auth:failed' });
      }
    }

    case 'subscribe': {
      const ids = Array.isArray(msg.conversationIds) ? msg.conversationIds.slice(0, 200) : [];
      const allowed = [];
      for (const id of ids) {
        if (typeof id === 'string' && (await isMember(meta.userId, id))) allowed.push(id);
      }
      meta.subscriptions = new Set(allowed);
      return send(ws, { type: 'subscribed', conversationIds: allowed });
    }

    case 'typing': {
      if (!(await isMember(meta.userId, msg.conversationId))) return;
      const members = await conversationMemberIds(msg.conversationId);
      sendToUsers(
        members,
        { type: 'typing', conversationId: msg.conversationId, userId: meta.userId, isTyping: Boolean(msg.isTyping) },
        { exceptUserId: meta.userId },
      );
      return;
    }

    case 'read': {
      if (!(await isMember(meta.userId, msg.conversationId))) return;
      await markConversationRead(meta.userId, msg.conversationId, msg.messageId);
      return;
    }

    case 'delivered': {
      const ids = Array.isArray(msg.messageIds) ? msg.messageIds.slice(0, 200) : [];
      if (!ids.length) return;
      const { rows } = await query(
        `select m.id, m.sender_id, m.conversation_id
           from messages m
           join conversation_members cm
             on cm.conversation_id = m.conversation_id and cm.user_id = $1 and cm.left_at is null
          where m.id = any($2::uuid[])`,
        [meta.userId, ids],
      );
      for (const row of rows) {
        await markDelivered(row.id, [meta.userId]);
        sendToUser(row.sender_id, {
          type: 'message:status',
          conversationId: row.conversation_id,
          messageId: row.id,
          status: 'delivered',
          at: new Date().toISOString(),
        });
      }
      return;
    }

    /* ------------------------- WebRTC signalling ------------------------- */

    case 'call:invite': {
      const { callId, toUserId, kind = 'audio', sdp } = msg;
      const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (!uuidPattern.test(String(callId)) || !uuidPattern.test(String(toUserId)) || toUserId === meta.userId) return;
      if (await blockedBetween(meta.userId, toUserId) || !(await areFriends(meta.userId, toUserId))) {
        return send(ws, { type: 'call:failed', callId, reason: 'not_allowed' });
      }
      const conversationId = await directConversationId(meta.userId, toUserId);
      if (!conversationId || (msg.conversationId && msg.conversationId !== conversationId)) {
        return send(ws, { type: 'call:failed', callId, reason: 'not_allowed' });
      }
      const { rows: meRows } = await query('select display_name, username, avatar_media_id from users where id = $1', [meta.userId]);
      const me = meRows[0];
      const inserted = await query(
        `insert into calls (id, conversation_id, caller_id, callee_id, kind, status, offer)
         values ($1, $2, $3, $4, $5, 'ringing', $6) on conflict (id) do nothing returning id`,
        [callId, conversationId, meta.userId, toUserId, kind === 'video' ? 'video' : 'audio', JSON.stringify(sdp || null)],
      );
      if (!inserted.rowCount) return send(ws, { type: 'call:failed', callId, reason: 'duplicate_call' });
      const delivered = sendToUser(toUserId, {
        type: 'call:incoming', callId, conversationId, kind, sdp,
        from: { id: meta.userId, displayName: me?.display_name || me?.username || 'Friend',
          username: me?.username, avatarUrl: me?.avatar_media_id ? signedMediaUrl(me.avatar_media_id) : null },
      });
      if (!delivered) {
        sendPushToUser(toUserId, {
          title: kind === 'video' ? 'Incoming video call' : 'Incoming call',
          body: `${me?.display_name || me?.username || 'A friend'} is calling you`,
          data: { type: 'call', callId, conversationId, kind, tag: `call_${callId}` },
          channelId: 'calls', highPriority: true,
        }).catch(() => {});
      }
      return send(ws, { type: 'call:ringing', callId, toUserId });
    }

    case 'call:answer':
    case 'call:reject':
    case 'call:end':
    case 'call:ice': {
      const { callId, toUserId } = msg;
      if (!/^[0-9a-f-]{36}$/i.test(String(callId || ''))) return;
      const { rows } = await query('select caller_id, callee_id, status, ended_at from calls where id = $1', [callId]);
      const call = rows[0];
      if (!call || (call.caller_id !== meta.userId && call.callee_id !== meta.userId)) return;
      const peer = call.caller_id === meta.userId ? call.callee_id : call.caller_id;
      if ((toUserId && toUserId !== peer) || await blockedBetween(meta.userId, peer)) return;
      if (call.ended_at) return;
      if (type === 'call:answer' && (call.callee_id !== meta.userId || call.status !== 'ringing')) return;
      if (type === 'call:ice' && msg.candidate && typeof msg.candidate === 'object') {
        await query(
          `insert into call_ice_candidates (call_id, from_user_id, candidate)
           select $1, $2, $3 where (select count(*) from call_ice_candidates where call_id = $1 and from_user_id = $2) < 100`,
          [callId, meta.userId, JSON.stringify(msg.candidate)],
        );
      }
      return relayCall(ws, meta, type, callId, peer, msg);
    }

    case 'presence:query': {
      const ids = Array.isArray(msg.userIds) ? msg.userIds.slice(0, 200) : [];
      const states = ids.map((id) => ({ userId: id, online: isOnline(id) }));
      return send(ws, { type: 'presence:result', states });
    }

    default:
      return send(ws, { type: 'error', code: 'unknown_type', message: `Unknown type ${type}` });
  }
}

async function relayCall(ws, meta, type, callId, peerId, msg) {
  const event = type.slice('call:'.length);
  if (callId) {
    if (event === 'answer') {
      await query("update calls set status = 'answered', answered_at = now() where id = $1 and status = 'ringing'", [
        callId,
      ]);
    } else if (event === 'reject') {
      await query("update calls set status = 'declined', ended_at = now() where id = $1 and status = 'ringing'", [
        callId,
      ]);
    } else if (event === 'end') {
      await query(
        `update calls set status = case when answered_at is null then 'missed' else 'ended' end,
                ended_at = now(), ended_reason = $2
          where id = $1 and ended_at is null`,
        [callId, msg.reason || null],
      );
    }
  }
  const payload = {
    type: `call:${event}`,
    callId,
    fromUserId: meta.userId,
    toUserId: peerId,
    sdp: msg.sdp,
    candidate: msg.candidate,
    reason: msg.reason,
  };
  const delivered = sendToUser(peerId, payload);
  if (!delivered && event === 'reject') {
    // Nobody to notify; nothing else to do.
  }
  send(ws, { type: 'call:ack', callId, event, delivered: delivered > 0 });
}

async function directConversationId(a, b) {
  const pairKey = [a, b].sort().join(':');
  const { rows } = await query('select id from conversations where pair_key = $1', [pairKey]);
  return rows[0]?.id || null;
}

/**
 * Mark a conversation read up to `messageId` (or everything not read yet).
 * Returns the message ids that flipped to read so senders can be notified.
 */
export async function markConversationRead(userId, conversationId, messageId) {
  const memberCheck = await isMember(userId, conversationId);
  if (!memberCheck) return { ok: false, updated: 0, senders: [] };

  const { rows: unread } = await query(
    `select m.id, m.sender_id
       from messages m
      where m.conversation_id = $1
        and m.sender_id <> $2
        and m.deleted_at is null
        and not exists (
          select 1 from message_receipts r
           where r.message_id = m.id and r.user_id = $2 and r.read_at is not null
        )
        and ($3::uuid is null or m.id = $3 or m.created_at <= (select created_at from messages where id = $3))
      order by m.created_at asc
      limit 500`,
    [conversationId, userId, messageId || null],
  );

  for (const row of unread) {
    await query(
      `insert into message_receipts (message_id, user_id, delivered_at, read_at)
       values ($1, $2, now(), now())
       on conflict (message_id, user_id)
       do update set delivered_at = coalesce(message_receipts.delivered_at, now()), read_at = now()`,
      [row.id, userId],
    );
  }
  await query(
    `update messages set read_at = coalesce(read_at, now())
      where id = any($1::uuid[]) and read_at is null`,
    [unread.map((r) => r.id)],
  );
  await query(
    `update conversation_members
        set last_read_at = coalesce((select created_at from messages where id = $3), now()),
            last_read_message_id = coalesce($3, last_read_message_id)
      where conversation_id = $1 and user_id = $2`,
    [conversationId, userId, messageId || null],
  );

  const senders = [...new Set(unread.map((r) => r.sender_id))];
  const at = new Date().toISOString();
  sendToUser(userId, { type: 'read:ack', conversationId, messageId: messageId || null, at });
  for (const senderId of senders) {
    sendToUser(senderId, {
      type: 'message:status',
      conversationId,
      messageIds: unread.filter((r) => r.sender_id === senderId).map((r) => r.id),
      status: 'read',
      at,
    });
  }
  return { ok: true, updated: unread.length, senders };
}

export function broadcastToUser(userId, payload) {
  return sendToUser(userId, payload);
}

export function initRealtime(server) {
  wss = new WebSocketServer({ server, path: '/ws', maxPayload: 256 * 1024 });

  wss.on('connection', async (ws, req) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const token = url.searchParams.get('token') || (req.headers.authorization || '').replace(/^Bearer /i, '');
    let userId = null;
    let expiresAt = 0;
    try {
      const payload = verifyAccessToken(token);
      userId = payload.sub;
      expiresAt = payload.exp * 1000;
      const { rows } = await query('select id, username, display_name, deleted_at from users where id = $1', [userId]);
      if (!rows[0] || rows[0].deleted_at) throw new Error('no such user');
    } catch {
      ws.send(JSON.stringify({ type: 'error', code: 'unauthorized', message: 'Invalid or expired token' }));
      ws.close(4001, 'unauthorized');
      return;
    }

    const meta = { userId, expiresAt, alive: true, subscriptions: new Set() };
    socketMeta.set(ws, meta);
    if (!connections.has(userId)) connections.set(userId, new Set());
    connections.get(userId).add(ws);

    ws.on('pong', () => {
      meta.alive = true;
    });
    // Process frames from each socket in order (an ICE candidate cannot race
    // the database insert for the preceding call invitation).
    let frames = Promise.resolve();
    ws.on('message', (raw) => {
      frames = frames.then(async () => {
        if (Date.now() >= meta.expiresAt) { ws.close(4001, 'token expired'); return; }
        await handleClientMessage(ws, meta, raw);
      }).catch((err) => {
        console.error('[ws] handler error', err.message);
        send(ws, { type: 'error', code: 'server_error', message: 'Something went wrong' });
      });
    });
    ws.on('close', () => {
      const set = connections.get(userId);
      if (set) {
        set.delete(ws);
        if (!set.size) {
          connections.delete(userId);
          // Tell friends that this user went offline (best effort).
          query('update users set last_seen_at = now() where id = $1', [userId]).catch(() => {});
        }
      }
    });
    ws.on('error', () => {});

    send(ws, {
      type: 'ready',
      userId,
      serverTime: new Date().toISOString(),
      heartbeatSeconds: 30,
    });
  });

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      const meta = socketMeta.get(ws);
      if (meta && Date.now() >= meta.expiresAt) { ws.close(4001, 'token expired'); continue; }
      if (meta && meta.alive === false) {
        ws.terminate();
        continue;
      }
      if (meta) meta.alive = false;
      try {
        ws.ping();
      } catch {
        /* ignore */
      }
    }
  }, 30_000);
  heartbeat.unref?.();

  wss.on('close', () => clearInterval(heartbeat));
  return wss;
}

export async function closeRealtime() {
  if (!wss) return;
  for (const ws of wss.clients) {
    try {
      ws.close(1001, 'server shutting down');
    } catch {
      /* ignore */
    }
  }
  await new Promise((resolve) => wss.close(resolve));
  wss = null;
}

export { sendToUsers as _sendToUsers, markDelivered as _markDelivered, env as _env };
