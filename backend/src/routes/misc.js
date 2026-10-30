import express from 'express';
import multer from 'multer';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { z } from 'zod';
import { env } from '../env.js';
import { query } from '../db.js';
import { asyncRoute, badRequest, notFound, unavailable } from '../errors.js';
import { requireAuth } from '../auth.js';
import { rateLimit } from '../ratelimit.js';
import { addInvite, betaConfig, checkBetaAccess } from '../beta.js';
import { pushConfigured } from '../push.js';
import { storageKind } from '../storage.js';
import { uuid } from '../util.js';
import { connectionCount } from '../realtime.js';

const router = express.Router();

const tmpDir = path.join(os.tmpdir(), 'worldfriends-feedback');
fs.mkdirSync(tmpDir, { recursive: true });
const upload = multer({ storage: multer.diskStorage({ destination: tmpDir }), limits: { fileSize: 12 * 1024 * 1024 } });

/* ------------------------------------------------------------------ *
 * Health
 * ------------------------------------------------------------------ */

router.get('/health', asyncRoute(async (req, res) => {
  let dbOk = false;
  try {
    await query('select 1');
    dbOk = true;
  } catch {
    dbOk = false;
  }
  res.status(dbOk ? 200 : 503).json({
    status: dbOk ? 'ok' : 'degraded',
    version: '1.0.0',
    time: new Date().toISOString(),
    database: dbOk,
    sockets: connectionCount(),
    features: {
      push: pushConfigured(),
      translation: Boolean(env.DEEPL_API_KEY || env.GOOGLE_TRANSLATE_API_KEY),
      storage: storageKind(),
      betaMode: env.BETA_MODE,
      googleSignIn: env.GOOGLE_CLIENT_IDS.length > 0,
      smtp: Boolean(env.SMTP_URL),
    },
  });
}));

/* ------------------------------------------------------------------ *
 * Beta
 * ------------------------------------------------------------------ */

router.get('/beta/config', asyncRoute(async (req, res) => {
  res.json(await betaConfig());
}));

router.post(
  '/beta/validate-invite',
  rateLimit({ limit: 30, windowMs: 15 * 60 * 1000, keyPrefix: 'invite' }),
  asyncRoute(async (req, res) => {
    const body = z.object({ code: z.string().trim().min(2).max(64), email: z.string().email().optional() }).parse(req.body);
    const result = await checkBetaAccess(body.email || 'unknown@example.com', body.code);
    res.json({ valid: result.allowed && ['env_invite', 'invite_code'].includes(result.reason), reason: result.reason });
  }),
);

/* ------------------------------------------------------------------ *
 * Feedback
 * ------------------------------------------------------------------ */

router.post(
  '/feedback',
  requireAuth,
  rateLimit({ limit: 20, windowMs: 60 * 60 * 1000, keyPrefix: 'feedback' }),
  upload.single('screenshot'),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        message: z.string().trim().min(3).max(4000),
        appVersion: z.string().max(40).optional(),
        deviceInfo: z.string().max(4000).optional(),
        includeLogs: z.string().optional(),
      })
      .parse(req.body ?? {});
    let deviceInfo = {};
    if (body.deviceInfo) {
      try {
        deviceInfo = JSON.parse(body.deviceInfo);
      } catch {
        deviceInfo = { raw: body.deviceInfo };
      }
    }

    let screenshotMediaId = null;
    if (req.file) {
      const { putStream } = await import('../storage.js');
      const id = uuid();
      const key = `feedback/${req.userId}/${id}${path.extname(req.file.originalname || '') || '.jpg'}`;
      await putStream(key, fs.createReadStream(req.file.path));
      await fs.promises.rm(req.file.path, { force: true });
      await query(
        `insert into media (id, owner_id, kind, mime, bytes, storage_key, original_name)
         values ($1,$2,'image',$3,$4,$5,$6)`,
        [id, req.userId, req.file.mimetype || 'image/jpeg', req.file.size, key, req.file.originalname || null],
      );
      screenshotMediaId = id;
    }

    const id = uuid();
    await query(
      `insert into feedback (id, user_id, message, device_info, app_version, screenshot_media_id)
       values ($1,$2,$3,$4,$5,$6)`,
      [id, req.userId, body.message, JSON.stringify(deviceInfo), body.appVersion || null, screenshotMediaId],
    );
    res.status(201).json({ id, status: 'received', message: 'Thanks! Your feedback reached the team.' });
  }),
);

/* ------------------------------------------------------------------ *
 * Anonymous analytics (never message content)
 * ------------------------------------------------------------------ */

const FORBIDDEN_PROP_KEYS = new Set([
  'message', 'body', 'text', 'content', 'caption', 'message_body', 'query', 'q',
  'snippet', 'transcript', 'email', 'phone', 'password', 'token', 'comment',
]);

function sanitizeProps(props) {
  if (!props || typeof props !== 'object') return {};
  const out = {};
  for (const [key, value] of Object.entries(props).slice(0, 20)) {
    if (FORBIDDEN_PROP_KEYS.has(String(key).toLowerCase())) continue;
    if (typeof value === 'string') out[key] = value.slice(0, 120);
    else if (typeof value === 'number' || typeof value === 'boolean') out[key] = value;
    else if (value === null) out[key] = null;
  }
  return out;
}

router.post(
  '/analytics/events',
  requireAuth,
  rateLimit({ limit: 120, windowMs: 60 * 1000, keyPrefix: 'analytics' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        anonId: z.string().max(64).optional(),
        appVersion: z.string().max(40).optional(),
        platform: z.string().max(20).optional(),
        events: z
          .array(
            z.object({
              name: z.string().min(1).max(60),
              props: z.record(z.string(), z.any()).optional(),
              at: z.string().optional(),
            }),
          )
          .max(50),
      })
      .parse(req.body);

    for (const event of body.events) {
      await query(
        `insert into analytics_events (user_id, anon_id, name, props, app_version, platform)
         values ($1,$2,$3,$4,$5,$6)`,
        [
          req.userId,
          body.anonId || null,
          event.name.slice(0, 60),
          JSON.stringify(sanitizeProps(event.props)),
          body.appVersion || null,
          body.platform || 'android',
        ],
      );
    }
    res.json({ accepted: body.events.length });
  }),
);

/* ------------------------------------------------------------------ *
 * Translation
 * ------------------------------------------------------------------ */

const translationCache = new Map(); // `${target}:${hash}` -> translated text

function cacheKey(text, target, source) {
  return `${source || 'auto'}:${target}:${text}`;
}

function remember(key, value) {
  if (translationCache.size > 500) {
    const first = translationCache.keys().next().value;
    translationCache.delete(first);
  }
  translationCache.set(key, value);
}

export function translationConfigured() {
  return Boolean(env.DEEPL_API_KEY || env.GOOGLE_TRANSLATE_API_KEY);
}

async function translateWithDeepL(text, target, source) {
  const isFree = env.DEEPL_API_KEY.trim().endsWith(':fx');
  const endpoint = isFree ? 'https://api-free.deepl.com/v2/translate' : 'https://api.deepl.com/v2/translate';
  const params = new URLSearchParams({ text, target_lang: target.toUpperCase() });
  if (source) params.set('source_lang', source.toUpperCase());
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      authorization: `DeepL-Auth-Key ${env.DEEPL_API_KEY}`,
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: params,
  });
  if (!res.ok) {
    const detail = await res.text();
    throw unavailable('translation_failed', 'Translation provider error', { status: res.status, detail: detail.slice(0, 200) });
  }
  const json = await res.json();
  const item = json.translations?.[0];
  return { text: item?.text || '', detectedSource: item?.detected_source_language || source || null, provider: 'deepl' };
}

async function translateWithGoogle(text, target, source) {
  const params = new URLSearchParams({ q: text, target, format: 'text' });
  if (source) params.set('source', source);
  const res = await fetch(
    `https://translation.googleapis.com/language/translate/v2?key=${encodeURIComponent(env.GOOGLE_TRANSLATE_API_KEY)}`,
    { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: params },
  );
  if (!res.ok) {
    const detail = await res.text();
    throw unavailable('translation_failed', 'Translation provider error', { status: res.status, detail: detail.slice(0, 200) });
  }
  const json = await res.json();
  const item = json.data?.translations?.[0];
  return { text: item?.translatedText || '', detectedSource: item?.detectedSourceLanguage || source || null, provider: 'google' };
}

router.post(
  '/translate',
  requireAuth,
  rateLimit({ limit: 60, windowMs: 60 * 1000, keyPrefix: 'translate' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        text: z.string().trim().min(1).max(4000),
        target: z.string().trim().min(2).max(10),
        source: z.string().trim().min(2).max(10).optional(),
      })
      .parse(req.body);

    if (!translationConfigured()) {
      throw unavailable('translation_not_configured', 'Translation is not configured on the server yet.', {
        hint: 'Set DEEPL_API_KEY or GOOGLE_TRANSLATE_API_KEY in the backend environment.',
      });
    }

    const key = cacheKey(body.text, body.target, body.source);
    if (translationCache.has(key)) {
      return res.json({ ...translationCache.get(key), cached: true });
    }

    const provider = env.TRANSLATE_PROVIDER || (env.DEEPL_API_KEY ? 'deepl' : 'google');
    const result =
      provider === 'google'
        ? await translateWithGoogle(body.text, body.target, body.source)
        : await translateWithDeepL(body.text, body.target, body.source);

    remember(key, result);
    return res.json({ ...result, cached: false });
  }),
);

router.get('/translate/languages', (req, res) => {
  res.json({
    configured: translationConfigured(),
    provider: env.TRANSLATE_PROVIDER || (env.DEEPL_API_KEY ? 'deepl' : env.GOOGLE_TRANSLATE_API_KEY ? 'google' : null),
    languages: [
      'en', 'es', 'fr', 'de', 'it', 'pt', 'pt-BR', 'nl', 'pl', 'ru', 'tr', 'ar', 'hi', 'pa', 'bn', 'ta',
      'te', 'mr', 'gu', 'ur', 'zh', 'ja', 'ko', 'vi', 'th', 'id', 'uk', 'sv', 'da', 'fi', 'no', 'cs', 'el', 'he',
    ],
  });
});

/* ------------------------------------------------------------------ *
 * Admin (owner only, guarded by ADMIN_TOKEN)
 * ------------------------------------------------------------------ */

function requireAdmin(req, res, next) {
  const token = req.headers['x-admin-token'] || req.query.adminToken;
  if (!env.ADMIN_TOKEN || String(token) !== env.ADMIN_TOKEN) {
    return next(notFound('not_found', 'Not found'));
  }
  return next();
}

router.post(
  '/admin/invites',
  requireAdmin,
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        code: z.string().trim().min(3).max(64).optional(),
        email: z.string().email().optional(),
        note: z.string().max(200).optional(),
        maxUses: z.number().int().min(1).max(500).optional(),
        expiresAt: z.string().datetime().optional(),
      })
      .parse(req.body ?? {});
    const code = body.code || `WF-${Math.random().toString(36).slice(2, 8).toUpperCase()}`;
    const invite = await addInvite({
      code,
      email: body.email,
      note: body.note,
      maxUses: body.maxUses || 1,
      expiresAt: body.expiresAt || null,
    });
    res.status(201).json({ invite });
  }),
);

router.get(
  '/admin/stats',
  requireAdmin,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select
         (select count(*)::int from users where deleted_at is null) as users,
         (select count(*)::int from users where email_verified_at is not null and deleted_at is null) as verified_users,
         (select count(*)::int from messages) as messages,
         (select count(*)::int from messages where created_at > now() - interval '24 hours') as messages_24h,
         (select count(*)::int from media) as media,
         (select coalesce(sum(bytes),0)::bigint from media) as media_bytes,
         (select count(*)::int from reports where status = 'open') as open_reports,
         (select count(*)::int from feedback) as feedback,
         (select count(*)::int from analytics_events where created_at > now() - interval '24 hours') as events_24h`,
    );
    res.json({ stats: rows[0], sockets: connectionCount() });
  }),
);

router.get(
  '/admin/feedback',
  requireAdmin,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select f.*, u.username from feedback f left join users u on u.id = f.user_id
        order by f.created_at desc limit 100`,
    );
    res.json({ feedback: rows });
  }),
);

router.get(
  '/admin/reports',
  requireAdmin,
  asyncRoute(async (req, res) => {
    const { rows } = await query(
      `select r.*, u.username as reporter from reports r left join users u on u.id = r.reporter_id
        order by r.created_at desc limit 100`,
    );
    res.json({ reports: rows });
  }),
);

export default router;
