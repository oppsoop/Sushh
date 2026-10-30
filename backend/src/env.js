import 'dotenv/config';
import crypto from 'node:crypto';

function bool(v, def = false) {
  if (v === undefined || v === null || v === '') return def;
  return ['1', 'true', 'yes', 'on'].includes(String(v).toLowerCase());
}

function int(v, def) {
  const n = Number.parseInt(v ?? '', 10);
  return Number.isFinite(n) ? n : def;
}

const NODE_ENV = process.env.NODE_ENV || 'development';
const isProd = NODE_ENV === 'production';

// In production a stable JWT secret is mandatory: rotating it silently logs out
// every user and invalidates in-flight refresh tokens.
function resolveJwtSecret() {
  const provided = process.env.JWT_SECRET;
  if (provided && provided.length >= 32) return provided;
  if (isProd) {
    throw new Error('JWT_SECRET must be set to at least 32 characters in production');
  }
  // Development / test fallback: stable within a process, clearly logged.
  return crypto.createHash('sha256').update(`dev-secret-${process.pid}`).digest('hex');
}

const publicUrl = (process.env.PUBLIC_URL || '').replace(/\/+$/, '');

export const env = {
  NODE_ENV,
  isProd,
  PORT: int(process.env.PORT, 8080),
  HOST: process.env.HOST || '0.0.0.0',
  PUBLIC_URL: publicUrl,
  DATABASE_URL: process.env.DATABASE_URL || 'postgresql://postgres@localhost:5432/worldfriends',
  DATABASE_SSL: bool(process.env.DATABASE_SSL, isProd && !/localhost|127\.0\.0\.1/.test(process.env.DATABASE_URL || '')),
  JWT_SECRET: resolveJwtSecret(),
  ACCESS_TOKEN_TTL: int(process.env.ACCESS_TOKEN_TTL_SECONDS, 900), // 15 minutes
  REFRESH_TOKEN_TTL: int(process.env.REFRESH_TOKEN_TTL_SECONDS, 60 * 60 * 24 * 60), // 60 days

  // Media
  MEDIA_DIR: process.env.MEDIA_DIR || './data/media',
  MEDIA_URL_TTL: int(process.env.MEDIA_URL_TTL_SECONDS, 60 * 60 * 12),
  MAX_UPLOAD_BYTES: int(process.env.MAX_UPLOAD_BYTES, 100 * 1024 * 1024),

  // Storage backend: local | s3
  STORAGE: (process.env.STORAGE || 'local').toLowerCase(),
  S3_BUCKET: process.env.S3_BUCKET || '',
  S3_REGION: process.env.S3_REGION || 'auto',
  S3_ENDPOINT: process.env.S3_ENDPOINT || '',
  S3_ACCESS_KEY_ID: process.env.S3_ACCESS_KEY_ID || '',
  S3_SECRET_ACCESS_KEY: process.env.S3_SECRET_ACCESS_KEY || '',

  // Email
  SMTP_URL: process.env.SMTP_URL || '',
  MAIL_FROM: process.env.MAIL_FROM || 'WorldFriends <no-reply@worldfriends.app>',
  APP_WEB_URL: (process.env.APP_WEB_URL || 'https://worldfriends.app').replace(/\/+$/, ''),
  ALLOW_DEV_CODES: !isProd && bool(process.env.ALLOW_DEV_CODES, true),

  // Google sign in (accepts one or more comma separated client ids)
  GOOGLE_CLIENT_IDS: (process.env.GOOGLE_CLIENT_IDS || process.env.GOOGLE_CLIENT_ID || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  // Push (FCM HTTP v1). Either a service account JSON (inline or file path).
  FCM_PROJECT_ID: process.env.FCM_PROJECT_ID || '',
  FCM_CLIENT_EMAIL: process.env.FCM_CLIENT_EMAIL || '',
  FCM_PRIVATE_KEY: (process.env.FCM_PRIVATE_KEY || '').replace(/\\n/g, '\n'),
  FCM_SERVICE_ACCOUNT_JSON: process.env.FCM_SERVICE_ACCOUNT_JSON || '',

  // Translation
  TRANSLATE_PROVIDER: (process.env.TRANSLATE_PROVIDER || '').toLowerCase(),
  DEEPL_API_KEY: process.env.DEEPL_API_KEY || '',
  GOOGLE_TRANSLATE_API_KEY: process.env.GOOGLE_TRANSLATE_API_KEY || '',

  // Beta gate
  BETA_MODE: bool(process.env.BETA_MODE, true),
  BETA_ALLOWED_EMAILS: (process.env.BETA_ALLOWED_EMAILS || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean),
  BETA_INVITE_CODES: (process.env.BETA_INVITE_CODES || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  BETA_ALLOW_ANY_EMAIL: bool(process.env.BETA_ALLOW_ANY_EMAIL, false),

  // Ops
  ADMIN_TOKEN: process.env.ADMIN_TOKEN || '',
  TRUST_PROXY: bool(process.env.TRUST_PROXY, true),
  CORS_ORIGINS: (process.env.CORS_ORIGINS || '*').split(',').map((s) => s.trim()),
  RATE_LIMIT_DISABLED: bool(process.env.RATE_LIMIT_DISABLED, NODE_ENV === 'test'),
  USERNAME_REUSE_COOLDOWN_DAYS: int(process.env.USERNAME_REUSE_COOLDOWN_DAYS, 90),
  USERNAME_CHANGE_COOLDOWN_DAYS: int(process.env.USERNAME_CHANGE_COOLDOWN_DAYS, 30),
};

export function requireProdConfig() {
  const problems = [];
  if (env.isProd && env.STORAGE === 'local') {
    problems.push('STORAGE=local on an ephemeral host will lose media on redeploy; configure S3 (e.g. Cloudflare R2).');
  }
  if (env.isProd && !env.PUBLIC_URL) problems.push('PUBLIC_URL is not set (used in verification links and media URLs).');
  if (env.isProd && env.SMTP_URL === '') problems.push('SMTP_URL is not set: email verification links will only be logged.');
  return problems;
}
