import express from 'express';
import { z } from 'zod';
import { asyncRoute, forbidden } from '../errors.js';
import { requireAuth } from '../auth.js';
import { rateLimit } from '../ratelimit.js';
import { checkAvailability, claimUsername, USERNAME_MAX, USERNAME_MIN } from '../username.js';
import { getUserById, selfUser } from '../service.js';

const router = express.Router();

/**
 * Live availability while typing. Intentionally generous rate limits: a client
 * debounces, but slow typists must never be locked out.
 */
router.get(
  '/available',
  rateLimit({ limit: 120, windowMs: 60 * 1000, keyPrefix: 'username-check' }),
  asyncRoute(async (req, res) => {
    const raw = String(req.query.username || req.query.u || '').slice(0, 64);
    // Optionally authenticated: lets "is it mine already" resolve as available.
    let userId = null;
    const header = req.headers.authorization || '';
    if (header.toLowerCase().startsWith('bearer ')) {
      try {
        const { verifyAccessToken } = await import('../auth.js');
        userId = verifyAccessToken(header.slice(7).trim()).sub;
      } catch {
        userId = null;
      }
    }
    const result = await checkAvailability(raw, userId);
    res.json({
      ...result,
      minLength: USERNAME_MIN,
      maxLength: USERNAME_MAX,
      checkedAt: new Date().toISOString(),
    });
  }),
);

router.post(
  '/claim',
  requireAuth,
  rateLimit({ limit: 20, windowMs: 60 * 60 * 1000, keyPrefix: 'username-claim' }),
  asyncRoute(async (req, res) => {
    const { username } = z.object({ username: z.string().min(1).max(64) }).parse(req.body);
    const result = await claimUsername(req.userId, username, { changing: false });
    const user = await getUserById(req.userId);
    res.status(201).json({
      username: result.username,
      user: selfUser(user),
      profileUrl: `https://worldfriends.app/@${result.username}`,
      message: 'Your username is yours.',
    });
  }),
);

router.post(
  '/change',
  requireAuth,
  rateLimit({ limit: 5, windowMs: 60 * 60 * 1000, keyPrefix: 'username-change' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({ username: z.string().min(1).max(64), confirm: z.literal(true) })
      .parse(req.body);
    if (!req.user.username) throw forbidden('no_username', 'Claim a username first.');
    const result = await claimUsername(req.userId, body.username, { changing: true });
    const user = await getUserById(req.userId);
    res.json({
      username: result.username,
      previous: result.previous,
      user: selfUser(user),
      profileUrl: `https://worldfriends.app/@${result.username}`,
      message: result.changed ? 'Username updated.' : 'That is already your username.',
    });
  }),
);

export default router;
