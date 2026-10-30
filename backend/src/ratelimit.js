import { env } from './env.js';
import { tooMany } from './errors.js';

/**
 * Small in-process fixed-window limiter. Good enough for a friends-and-family
 * beta on a single instance; swap for Redis if the API is scaled out.
 */
const buckets = new Map();

function hit(key, limit, windowMs) {
  const now = Date.now();
  const bucket = buckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    return { allowed: true, remaining: limit - 1, resetAt: now + windowMs };
  }
  bucket.count += 1;
  return { allowed: bucket.count <= limit, remaining: Math.max(0, limit - bucket.count), resetAt: bucket.resetAt };
}

export function rateLimit({ limit = 60, windowMs = 60_000, keyPrefix = '', by = 'ip' } = {}) {
  return (req, res, next) => {
    if (env.RATE_LIMIT_DISABLED) return next();
    const identity = by === 'user' ? req.userId || req.ip : by === 'email' ? String(req.body?.email || '').trim().toLowerCase() || req.ip : req.ip;
    const key = `${keyPrefix}:${identity}:${Math.floor(Date.now() / windowMs)}`;
    const result = hit(key, limit, windowMs);
    res.setHeader('X-RateLimit-Limit', String(limit));
    res.setHeader('X-RateLimit-Remaining', String(result.remaining));
    if (!result.allowed) {
      res.setHeader('Retry-After', String(Math.ceil((result.resetAt - Date.now()) / 1000)));
      return next(tooMany());
    }
    return next();
  };
}

// Periodic cleanup so the map cannot grow unbounded on a long-lived process.
setInterval(() => {
  const now = Date.now();
  for (const [key, value] of buckets) {
    if (value.resetAt <= now) buckets.delete(key);
  }
}, 60_000).unref?.();
