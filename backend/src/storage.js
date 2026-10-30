import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { env } from './env.js';

/* ------------------------------------------------------------------ *
 * Storage abstraction.
 *
 *  local : files on disk, served by this API (fine for the beta; use a
 *          persistent volume, or switch to S3 for ephemeral hosts).
 *  s3    : any S3 compatible bucket (Cloudflare R2, Backblaze B2, AWS).
 *          Objects are signed with SigV4 so the app can hand the URL to
 *          Android's video/audio players, which cannot send auth headers.
 * ------------------------------------------------------------------ */

const MEDIA_ROOT = path.resolve(env.MEDIA_DIR);

export function storageKind() {
  return env.STORAGE === 's3' && env.S3_BUCKET ? 's3' : 'local';
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function localPathForKey(key) {
  const safe = key.replace(/\.\./g, '').replace(/^\/+/, '');
  return path.join(MEDIA_ROOT, safe);
}

/* ------------------------------ S3 SigV4 ------------------------------ */

function sha256hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}
function hmacBuf(key, data) {
  return crypto.createHmac('sha256', key).update(data).digest();
}

function s3Host() {
  if (env.S3_ENDPOINT) return new URL(env.S3_ENDPOINT).host;
  return `${env.S3_BUCKET}.s3.${env.S3_REGION}.amazonaws.com`;
}

function signedS3Request({ method, key, expires = 900, body }) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const region = env.S3_REGION === 'auto' ? 'auto' : env.S3_REGION;
  const host = s3Host();
  const canonicalUri = `/${env.S3_BUCKET}/${key.split('/').map(encodeURIComponent).join('/')}`;
  const scope = `${dateStamp}/${region}/s3/aws4_request`;

  const params = new URLSearchParams({
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${env.S3_ACCESS_KEY_ID}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(expires),
    'X-Amz-SignedHeaders': 'host',
  });
  const canonicalQuery = [...params.entries()]
    .sort(([a], [b]) => (a < b ? -1 : 1))
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&');

  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQuery,
    `host:${host}\n`,
    'host',
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256hex(canonicalRequest)].join('\n');
  const kDate = hmacBuf(`AWS4${env.S3_SECRET_ACCESS_KEY}`, dateStamp);
  const kRegion = hmacBuf(kDate, region);
  const kService = hmacBuf(kRegion, 's3');
  const kSigning = hmacBuf(kService, 'aws4_request');
  const signature = crypto.createHmac('sha256', kSigning).update(stringToSign).digest('hex');

  const base = env.S3_ENDPOINT
    ? `${env.S3_ENDPOINT.replace(/\/+$/, '')}${canonicalUri}`
    : `https://${host}${canonicalUri}`;
  return { url: `${base}?${canonicalQuery}&X-Amz-Signature=${signature}`, host };
}

/* ------------------------------ Public API ------------------------------ */

export async function putObject(key, buffer, contentType, { cacheControl } = {}) {
  if (storageKind() === 's3') {
    const url = signedS3Request({ method: 'PUT', key, expires: 900 });
    // The signature above uses UNSIGNED-PAYLOAD, so content-type must not be signed.
    const res = await fetch(url, {
      method: 'PUT',
      headers: { 'content-type': contentType || 'application/octet-stream' },
      body: buffer,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`s3 put failed: ${res.status} ${text.slice(0, 200)}`);
    }
    return { key, storage: 's3' };
  }

  const full = localPathForKey(key);
  ensureDir(path.dirname(full));
  await fsp.writeFile(full, buffer);
  return { key, storage: 'local' };
}

export async function putStream(key, readableStream) {
  if (storageKind() === 's3') {
    const chunks = [];
    for await (const chunk of readableStream) chunks.push(chunk);
    return putObject(key, Buffer.concat(chunks), 'application/octet-stream');
  }
  const full = localPathForKey(key);
  ensureDir(path.dirname(full));
  const tmp = `${full}.part`;
  await new Promise((resolve, reject) => {
    const out = fs.createWriteStream(tmp);
    readableStream.pipe(out);
    readableStream.on('error', reject);
    out.on('error', reject);
    out.on('finish', resolve);
  });
  await fsp.rename(tmp, full);
  return { key, storage: 'local' };
}

export async function getObjectStream(key) {
  const full = localPathForKey(key);
  const stat = await fsp.stat(full);
  return { stream: fs.createReadStream(full), size: stat.size };
}

export async function deleteObject(key) {
  if (!key) return;
  if (storageKind() === 's3') {
    try {
      const url = signedS3Request({ method: 'DELETE', key, expires: 300 });
      await fetch(url, { method: 'DELETE' });
    } catch (err) {
      console.error('[storage] s3 delete failed', err.message);
    }
    return;
  }
  await fsp.rm(localPathForKey(key), { force: true });
}

/** A time limited URL that Android media players can open without headers. */
export function signedMediaUrl(mediaId, { ttl = env.MEDIA_URL_TTL, variant = 'content' } = {}) {
  const exp = Math.floor(Date.now() / 1000) + ttl;
  const sig = crypto
    .createHmac('sha256', env.JWT_SECRET)
    .update(`${mediaId}:${variant}:${exp}`)
    .digest('base64url');
  return `/v1/media/${mediaId}/${variant}?exp=${exp}&sig=${sig}`;
}

export function verifyMediaSignature(mediaId, variant, exp, sig) {
  const expNum = Number(exp);
  if (!Number.isFinite(expNum) || expNum * 1000 < Date.now()) return false;
  const expected = crypto
    .createHmac('sha256', env.JWT_SECRET)
    .update(`${mediaId}:${variant}:${expNum}`)
    .digest('base64url');
  const a = Buffer.from(String(sig || ''));
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export function s3DownloadUrl(key, ttl = env.MEDIA_URL_TTL) {
  return signedS3Request({ method: 'GET', key, expires: ttl }).url;
}

export const mediaRoot = MEDIA_ROOT;
