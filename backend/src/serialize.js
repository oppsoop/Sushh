import { signedMediaUrl } from './storage.js';

export function serializeMedia(row) {
  if (!row) return null;
  return {
    id: row.id,
    kind: row.kind,
    mime: row.mime,
    bytes: Number(row.bytes ?? 0),
    width: row.width ?? null,
    height: row.height ?? null,
    durationMs: row.duration_ms ?? null,
    originalName: row.original_name ?? null,
    // Time-limited, header-free URLs: Android media players cannot send
    // Authorization headers, so these URLs are self-authenticating.
    url: signedMediaUrl(row.id),
    thumbUrl: row.thumb_key ? signedMediaUrl(row.id, { variant: 'thumb' }) : null,
    createdAt: row.created_at,
  };
}

export function serializeMessage(row, { receipts, media } = {}) {
  const delivery = receipts || {};
  return {
    id: row.id,
    clientId: row.client_id,
    conversationId: row.conversation_id,
    senderId: row.sender_id,
    kind: row.kind,
    body: row.deleted_at ? null : row.body,
    media: media !== undefined ? serializeMedia(media) : row.media_id ? { id: row.media_id } : null,
    mediaId: row.media_id || null,
    replyToId: row.reply_to_id || null,
    createdAt: row.created_at,
    editedAt: row.edited_at || null,
    deletedAt: row.deleted_at || null,
    status: delivery.status || (row.read_at ? 'read' : row.delivered_at ? 'delivered' : 'sent'),
    deliveredAt: row.delivered_at || null,
    readAt: row.read_at || null,
  };
}

export function serializeProfile(row, extra = {}) {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name ?? '',
    bio: row.bio ?? '',
    avatarUrl: row.avatar_media_id ? signedMediaUrl(row.avatar_media_id) : null,
    avatarMediaId: row.avatar_media_id || null,
    profileUrl: row.username ? `https://worldfriends.app/@${row.username}` : null,
    online: extra.online ?? false,
    lastSeenAt: row.last_seen_at || null,
    ...extra,
  };
}
