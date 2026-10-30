import express from 'express';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import multer from 'multer';
import { z } from 'zod';
import { env } from '../env.js';
import { query } from '../db.js';
import { asyncRoute, badRequest, forbidden, notFound } from '../errors.js';
import { requireAuth } from '../auth.js';
import { blockedEither } from '../friends.js';
import { rateLimit } from '../ratelimit.js';
import { deleteObject, getObjectStream, putObject, putStream, signedMediaUrl, s3DownloadUrl, storageKind, verifyMediaSignature } from '../storage.js';
import { serializeMedia } from '../serialize.js';
import { uuid } from '../util.js';

const router = express.Router();

const tmpDir = path.join(os.tmpdir(), 'worldfriends-uploads');
fs.mkdirSync(tmpDir, { recursive: true });

const upload = multer({
  storage: multer.diskStorage({ destination: tmpDir }),
  limits: { fileSize: env.MAX_UPLOAD_BYTES, files: 2 },
});

function classify(mime = '') {
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  return 'file';
}

function extensionFor(name, mime) {
  const fromName = path.extname(name || '').slice(0, 12);
  if (fromName) return fromName.toLowerCase();
  const map = {
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/webp': '.webp',
    'image/gif': '.gif',
    'image/heic': '.heic',
    'video/mp4': '.mp4',
    'video/quicktime': '.mov',
    'video/webm': '.webm',
    'audio/mp4': '.m4a',
    'audio/aac': '.aac',
    'audio/mpeg': '.mp3',
    'audio/ogg': '.ogg',
    'audio/wav': '.wav',
    'audio/3gpp': '.3gp',
    'audio/amr': '.amr',
  };
  return map[mime] || '';
}

/**
 * Access rules for a media object.
 * Owner, members of a conversation that contains it, friends looking at a
 * story, and anyone who can see the post that embeds it.
 */
async function canViewMedia(userId, mediaRow) {
  if (!mediaRow) return false;
  if (!userId) return false;
  if (mediaRow.owner_id === userId) return true;
  if (await blockedEither(userId, mediaRow.owner_id)) return false;

  const { rows: viaMessage } = await query(
    `select 1 from messages m
       join conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = $2 and cm.left_at is null
      where m.media_id = $1 and m.deleted_at is null limit 1`,
    [mediaRow.id, userId],
  );
  if (viaMessage.length) return true;

  const { rows: viaStory } = await query(
    `select 1 from stories s
      where s.media_id = $1 and s.deleted_at is null and s.expires_at > now()
        and (s.user_id = $2 or exists (
          select 1 from follows f where f.follower_id = $2 and f.following_id = s.user_id
        ) or exists (select 1 from friendships fr where fr.user_a = least(s.user_id, $2::uuid) and fr.user_b = greatest(s.user_id, $2::uuid))) limit 1`,
    [mediaRow.id, userId],
  );
  if (viaStory.length) return true;

  const { rows: viaPost } = await query(
    `select 1 from posts p
      where p.media_id = $1 and p.deleted_at is null
        and (p.visibility = 'public' or p.user_id = $2
             or (p.visibility = 'friends' and exists (
               select 1 from friendships f
                where f.user_a = least(p.user_id, $2::uuid) and f.user_b = greatest(p.user_id, $2::uuid)
             )))
      limit 1`,
    [mediaRow.id, userId],
  );
  if (viaPost.length) return true;

  const { rows: viaAvatar } = await query('select 1 from users where avatar_media_id = $1 limit 1', [mediaRow.id]);
  return viaAvatar.length > 0;
}

async function loadMedia(id) {
  const { rows } = await query('select * from media where id = $1', [id]);
  return rows[0] || null;
}

/* ------------------------------------------------------------------ *
 * Upload
 * ------------------------------------------------------------------ */

router.post(
  '/media',
  requireAuth,
  rateLimit({ limit: 60, windowMs: 10 * 60 * 1000, keyPrefix: 'upload' }),
  upload.single('file'),
  asyncRoute(async (req, res) => {
    if (!req.file) throw badRequest('missing_file', 'No file uploaded (field name must be "file")');
    const mime = req.file.mimetype || 'application/octet-stream';
    const kind = req.body.kind && ['image', 'video', 'audio', 'file'].includes(req.body.kind)
      ? req.body.kind
      : classify(mime);
    const id = uuid();
    const now = new Date();
    const key = `u/${req.userId}/${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, '0')}/${id}${extensionFor(req.file.originalname, mime)}`;

    let bytes = req.file.size;
    if (storageKind() === 's3') {
      const buffer = await fsp.readFile(req.file.path);
      await putObject(key, buffer, mime);
      await fsp.rm(req.file.path, { force: true });
    } else {
      await putStream(key, fs.createReadStream(req.file.path));
      const stat = await fsp.stat(req.file.path);
      bytes = stat.size;
      await fsp.rm(req.file.path, { force: true });
    }

    const durationMs = req.body.durationMs ? Number.parseInt(req.body.durationMs, 10) : null;
    const width = req.body.width ? Number.parseInt(req.body.width, 10) : null;
    const height = req.body.height ? Number.parseInt(req.body.height, 10) : null;

    const { rows } = await query(
      `insert into media (id, owner_id, kind, mime, bytes, width, height, duration_ms, storage_key, original_name, waveform)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       returning *`,
      [
        id,
        req.userId,
        kind,
        mime,
        bytes,
        Number.isFinite(width) ? width : null,
        Number.isFinite(height) ? height : null,
        Number.isFinite(durationMs) ? durationMs : null,
        key,
        req.file.originalname?.slice(0, 200) || null,
        req.body.waveform?.slice(0, 2000) || null,
      ],
    );
    res.status(201).json({ media: serializeMedia(rows[0]) });
  }),
);

/* ------------------------------------------------------------------ *
 * Download / stream
 * ------------------------------------------------------------------ */

async function streamLocal(req, res, media, variant) {
  const key = variant === 'thumb' && media.thumb_key ? media.thumb_key : media.storage_key;
  const { stream, size } = await getObjectStream(key);
  res.setHeader('Content-Type', media.mime || 'application/octet-stream');
  res.setHeader('Cache-Control', 'private, max-age=3600');
  res.setHeader('Accept-Ranges', 'bytes');
  if (variant !== 'thumb') {
    const name = (media.original_name || `${media.id}`).replace(/[^a-zA-Z0-9._ -]/g, '_');
    res.setHeader('Content-Disposition', `inline; filename="${name}"`);
  }

  // Range support so Android's video player can seek.
  const range = req.headers.range;
  if (range && /^bytes=\d*-\d*$/.test(range)) {
    stream.destroy();
    const [startStr, endStr] = range.replace('bytes=', '').split('-');
    const start = startStr ? Number.parseInt(startStr, 10) : Math.max(0, size - Number.parseInt(endStr || '0', 10));
    const end = startStr && endStr ? Math.min(Number.parseInt(endStr, 10), size - 1) : size - 1;
    if (start >= size || end >= size || start > end) {
      res.status(416).setHeader('Content-Range', `bytes */${size}`);
      return res.end();
    }
    res.status(206);
    res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
    res.setHeader('Content-Length', String(end - start + 1));
    const partial = fs.createReadStream(path.join(env.MEDIA_DIR, key), { start, end });
    partial.pipe(res);
    return undefined;
  }

  res.setHeader('Content-Length', String(size));
  stream.pipe(res);
  return undefined;
}

async function serveMedia(req, res, variant) {
  const media = await loadMedia(req.params.id);
  if (!media || media.deleted_at) throw notFound('media_not_found', 'Media not found');

  const sigOk = verifyMediaSignature(media.id, variant, req.query.exp, req.query.sig);
  let authorized = sigOk;
  if (!authorized) {
    const header = req.headers.authorization || '';
    if (header.toLowerCase().startsWith('bearer ')) {
      try {
        const { verifyAccessToken } = await import('../auth.js');
        const payload = verifyAccessToken(header.slice(7).trim());
        authorized = await canViewMedia(payload.sub, media);
      } catch {
        authorized = false;
      }
    }
  }
  if (!authorized) throw forbidden('media_forbidden', 'Not allowed to view this media');

  if (storageKind() === 's3') {
    const key = variant === 'thumb' && media.thumb_key ? media.thumb_key : media.storage_key;
    res.redirect(302, s3DownloadUrl(key, 3600));
    return;
  }
  await streamLocal(req, res, media, variant);
}

router.get('/media/:id/content', asyncRoute((req, res) => serveMedia(req, res, 'content')));
router.get('/media/:id/thumb', asyncRoute((req, res) => serveMedia(req, res, 'thumb')));

router.get(
  '/media/:id/url',
  requireAuth,
  asyncRoute(async (req, res) => {
    const media = await loadMedia(req.params.id);
    if (!media || media.deleted_at) throw notFound('media_not_found', 'Media not found');
    if (!(await canViewMedia(req.userId, media))) throw forbidden('media_forbidden', 'Not allowed to view this media');
    res.json({
      id: media.id,
      url: signedMediaUrl(media.id, { ttl: env.MEDIA_URL_TTL }),
      thumbUrl: media.thumb_key ? signedMediaUrl(media.id, { ttl: env.MEDIA_URL_TTL, variant: 'thumb' }) : null,
      expiresAt: new Date(Date.now() + env.MEDIA_URL_TTL * 1000).toISOString(),
      mime: media.mime,
      kind: media.kind,
      bytes: Number(media.bytes),
      originalName: media.original_name,
    });
  }),
);

router.get(
  '/media/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const media = await loadMedia(req.params.id);
    if (!media || media.deleted_at) throw notFound('media_not_found', 'Media not found');
    if (!(await canViewMedia(req.userId, media))) throw forbidden('media_forbidden', 'Not allowed to view this media');
    res.json({ media: serializeMedia(media) });
  }),
);

router.delete(
  '/media/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const media = await loadMedia(req.params.id);
    if (!media || media.owner_id !== req.userId) throw notFound('media_not_found', 'Media not found');
    await query('update media set deleted_at = now() where id = $1', [media.id]);
    await deleteObject(media.storage_key);
    res.json({ status: 'deleted' });
  }),
);

export { upload, canViewMedia, loadMedia };
export default router;

/* ------------------------------------------------------------------ *
 * Stories
 * ------------------------------------------------------------------ */

export const storiesRouter = express.Router();

storiesRouter.post(
  '/stories',
  requireAuth,
  rateLimit({ limit: 40, windowMs: 60 * 60 * 1000, keyPrefix: 'story' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        mediaId: z.string().uuid().optional(),
        caption: z.string().max(300).optional(),
        backgroundColor: z.string().max(20).optional(),
      })
      .parse(req.body ?? {});
    if (!body.mediaId && !body.caption?.trim()) {
      throw badRequest('empty_story', 'Add a photo/video or some text');
    }
    if (body.mediaId) {
      const { rows } = await query('select owner_id from media where id = $1 and deleted_at is null', [body.mediaId]);
      if (!rows[0] || rows[0].owner_id !== req.userId) throw badRequest('invalid_media', 'Unknown media');
    }
    const id = uuid();
    const { rows } = await query(
      `insert into stories (id, user_id, media_id, caption, background_color, expires_at)
       values ($1, $2, $3, $4, $5, now() + interval '24 hours') returning *`,
      [id, req.userId, body.mediaId || null, body.caption || '', body.backgroundColor || null],
    );
    const story = rows[0];
    const { rows: mediaRows } = body.mediaId ? await query('select * from media where id = $1', [body.mediaId]) : { rows: [] };

    const { rows: followerRows } = await query(
      `select f.follower_id from follows f join friendships fr
          on fr.user_a = least(f.follower_id, $1::uuid) and fr.user_b = greatest(f.follower_id, $1::uuid)
        where f.following_id = $1`,
      [req.userId],
    );
    const { sendToUser } = await import('../realtime.js');
    for (const follower of followerRows) {
      sendToUser(follower.follower_id, { type: 'story:new', storyId: story.id, userId: req.userId });
    }
    res.status(201).json({
      story: {
        id: story.id,
        caption: story.caption,
        media: mediaRows[0] ? serializeMedia(mediaRows[0]) : null,
        createdAt: story.created_at,
        expiresAt: story.expires_at,
        viewed: false,
      },
    });
  }),
);

storiesRouter.get(
  '/stories',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select s.*, u.username, u.display_name, u.avatar_media_id,
              md.id as m_id, md.kind as m_kind, md.mime as m_mime, md.bytes as m_bytes,
              md.width as m_width, md.height as m_height, md.duration_ms as m_duration,
              md.original_name as m_name, md.created_at as m_created_at,
              (select 1 from story_views v where v.story_id = s.id and v.viewer_id = $1) as viewed
         from stories s
         join users u on u.id = s.user_id
         left join media md on md.id = s.media_id
        where s.deleted_at is null and s.expires_at > now()
          and (s.user_id = $1
               or exists (select 1 from follows f where f.follower_id = $1 and f.following_id = s.user_id)
               or exists (select 1 from friendships fr
                          where fr.user_a = least(s.user_id, $1::uuid) and fr.user_b = greatest(s.user_id, $1::uuid)))
          and not exists (select 1 from blocks b
                where (b.blocker_id = $1 and b.blocked_id = s.user_id) or (b.blocker_id = s.user_id and b.blocked_id = $1))
        order by s.created_at desc
        limit 200`,
      [req.userId],
    );

    const groups = new Map();
    for (const row of rows) {
      if (!groups.has(row.user_id)) {
        groups.set(row.user_id, {
          user: {
            id: row.user_id,
            username: row.username,
            displayName: row.display_name,
            avatarUrl: row.avatar_media_id ? signedMediaUrl(row.avatar_media_id) : null,
          },
          isMe: row.user_id === req.userId,
          allViewed: true,
          stories: [],
        });
      }
      const group = groups.get(row.user_id);
      if (!row.viewed) group.allViewed = false;
      group.stories.push({
        id: row.id,
        caption: row.caption,
        backgroundColor: row.background_color,
        createdAt: row.created_at,
        expiresAt: row.expires_at,
        viewed: Boolean(row.viewed),
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
      });
    }
    res.json({ groups: [...groups.values()] });
  }),
);

storiesRouter.post(
  '/stories/:id/view',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select s.* from stories s where s.id = $1 and s.deleted_at is null and s.expires_at > now()
        and (s.user_id = $2 or exists (select 1 from follows f where f.follower_id = $2 and f.following_id = s.user_id)
             or exists (select 1 from friendships fr where fr.user_a = least(s.user_id, $2::uuid) and fr.user_b = greatest(s.user_id, $2::uuid)))
        and not exists (select 1 from blocks b where (b.blocker_id = $2 and b.blocked_id = s.user_id) or (b.blocker_id = s.user_id and b.blocked_id = $2))`,
      [req.params.id, req.userId]);
    const story = rows[0];
    if (!story) throw notFound('story_not_found', 'Story not found');
    await query(
      'insert into story_views (story_id, viewer_id) values ($1, $2) on conflict do nothing',
      [story.id, req.userId],
    );
    res.json({ status: 'ok' });
  }),
);

storiesRouter.delete(
  '/stories/:id',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rowCount } = await query('update stories set deleted_at = now() where id = $1 and user_id = $2', [
      req.params.id,
      req.userId,
    ]);
    if (!rowCount) throw notFound('story_not_found', 'Story not found');
    res.json({ status: 'deleted' });
  }),
);

storiesRouter.get(
  '/stories/:id/viewers',
  requireAuth,
  asyncRoute(async (req, res) => {
    const { rows: own } = await query('select 1 from stories where id = $1 and user_id = $2', [
      req.params.id,
      req.userId,
    ]);
    if (!own.length) throw forbidden('not_owner', 'Only the owner can see viewers');
    const { rows } = await query(
      `select u.id, u.username, u.display_name, u.avatar_media_id, v.viewed_at
         from story_views v join users u on u.id = v.viewer_id
        where v.story_id = $1 order by v.viewed_at desc limit 100`,
      [req.params.id],
    );
    res.json({
      viewers: rows.map((row) => ({
        id: row.id,
        username: row.username,
        displayName: row.display_name,
        avatarUrl: row.avatar_media_id ? signedMediaUrl(row.avatar_media_id) : null,
        viewedAt: row.viewed_at,
      })),
    });
  }),
);
