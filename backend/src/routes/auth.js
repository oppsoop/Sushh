import express from 'express';
import { z } from 'zod';
import { env } from '../env.js';
import { query } from '../db.js';
import { asyncRoute, ApiError, badRequest, conflict, unauthorized } from '../errors.js';
import { rateLimit } from '../ratelimit.js';
import {
  consumeEmailToken,
  createEmailToken,
  resetUrl,
  revokeAllSessions,
  revokeRefreshToken,
  rotateRefreshToken,
  verificationUrl,
  verifyGoogleIdToken,
} from '../auth.js';
import { recentMails, sendPasswordResetEmail, sendVerificationEmail } from '../mailer.js';
import { checkBetaAccess, consumeInvite } from '../beta.js';
import { bootstrap, createSession, getUserByEmail, getUserById, selfUser } from '../service.js';
import { hashPassword, isEmail, normalizeEmail, randomCode, uuid, verifyPassword } from '../util.js';
import { requireAuth } from '../auth.js';
import { checkAvailability, claimUsername, suggestionsFor } from '../username.js';
import { signAccessToken } from '../auth.js';

const router = express.Router();

const passwordSchema = z
  .string()
  .min(8, 'Password must be at least 8 characters')
  .max(200, 'Password is too long');

const emailSchema = z.string().trim().min(3).max(254).refine(isEmail, 'Enter a valid email address');

/** Username ideas derived from the email/display name. */
export function usernameIdeas(email, displayName) {
  const candidates = [];
  const fromName = String(displayName || '')
    .toLowerCase()
    .replace(/[^a-z0-9._]/g, '')
    .replace(/^[^a-z]+/, '')
    .slice(0, 16);
  const fromEmail = String(email || '').split('@')[0].toLowerCase().replace(/[^a-z0-9._]/g, '');
  if (fromName.length >= 3) candidates.push(fromName);
  if (fromEmail.length >= 3) candidates.push(fromEmail.replace(/^[^a-z]+/, ''));
  const out = new Set();
  for (const base of candidates) {
    for (const variant of [base, `${base}${Math.floor(Math.random() * 89) + 10}`, `${base}_`, `${base}.${new Date().getFullYear()}`]) {
      const clean = variant.slice(0, 20).replace(/\.$/, '');
      if (clean.length >= 3) out.add(clean);
    }
  }
  return [...out].slice(0, 5);
}

/* ------------------------------------------------------------------ *
 * Register
 * ------------------------------------------------------------------ */

router.post(
  '/register',
  rateLimit({ limit: 10, windowMs: 60 * 60 * 1000, keyPrefix: 'register' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        email: emailSchema,
        password: passwordSchema,
        displayName: z.string().trim().min(1).max(60).optional(),
        inviteCode: z.string().trim().max(64).optional(),
      })
      .parse(req.body);

    const email = normalizeEmail(body.email);
    const gate = await checkBetaAccess(email, body.inviteCode);
    if (!gate.allowed) {
      throw new ApiError(403, gate.reason || 'beta_closed', gate.message || 'Registration is restricted.');
    }

    const existing = await getUserByEmail(email);
    if (existing) {
      if (existing.deleted_at) {
        throw conflict('account_deleted', 'This account was deleted. Contact the owner to restore it.');
      }
      if (existing.email_verified_at) {
        throw conflict('email_taken', 'An account with this email already exists. Try signing in.');
      }
      // Unverified account: allow re-registration to refresh the code.
      await query('delete from email_tokens where user_id = $1 and purpose = $2', [existing.id, 'verify_email']);
      const code = randomCode(6);
      const token = await createEmailToken(existing.id, 'verify_email', 30);
      await sendVerificationEmail(email, code, verificationUrl(token));
      await query('insert into email_tokens (id, user_id, token_hash, purpose, expires_at) values ($1,$2,$3,$4,$5)', [
        uuid(),
        existing.id,
        `code:${code}:${existing.id}`,
        'verify_email',
        new Date(Date.now() + 30 * 60 * 1000),
      ]);
      return res.status(200).json({
        status: 'verification_sent',
        email,
        message: 'We sent a fresh verification code.',
        devCode: env.ALLOW_DEV_CODES ? code : undefined,
      });
    }

    const userId = uuid();
    const passwordHash = await hashPassword(body.password);
    await query(
      `insert into users (id, email, password_hash, display_name, created_at, updated_at)
       values ($1, $2, $3, $4, now(), now())`,
      [userId, email, passwordHash, (body.displayName || email.split('@')[0]).slice(0, 60)],
    );

    await consumeInvite({ inviteId: gate.inviteId, code: gate.code, email });

    // Email verification: a 6 digit code (easy to type on a phone) and a link.
    const code = randomCode(6);
    const token = await createEmailToken(userId, 'verify_email', 30);
    await query(
      `insert into email_tokens (id, user_id, token_hash, purpose, expires_at)
       values ($1, $2, $3, 'verify_email', now() + interval '30 minutes')`,
      [uuid(), userId, `code:${code}:${userId}`],
    );
    const mail = await sendVerificationEmail(email, code, verificationUrl(token));

    res.status(201).json({
      status: 'verification_sent',
      userId,
      email,
      emailDelivered: mail.delivered,
      message: 'Check your inbox for the 6-digit code (or the verification link).',
      devCode: env.ALLOW_DEV_CODES ? code : undefined,
      usernameIdeas: usernameIdeas(email, body.displayName),
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Verify email (code or link token) -> creates the session
 * ------------------------------------------------------------------ */

async function verifyCodeFor(userId, code) {
  const { rows } = await query(
    `select id from email_tokens
      where user_id = $1 and purpose = 'verify_email' and token_hash = $2 and used_at is null
        and expires_at > now()
      order by created_at desc limit 1`,
    [userId, `code:${String(code || '').trim()}:${userId}`],
  );
  return rows[0] || null;
}

router.post(
  '/verify-email',
  rateLimit({ limit: 30, windowMs: 15 * 60 * 1000, keyPrefix: 'verify' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        email: emailSchema.optional(),
        code: z.string().trim().min(4).max(12).optional(),
        token: z.string().trim().min(10).optional(),
      })
      .parse(req.body);

    let userId = null;
    if (body.token) {
      const consumed = await consumeEmailToken(body.token, 'verify_email');
      if (!consumed) throw badRequest('invalid_token', 'That verification link is invalid or has expired.');
      userId = consumed.userId;
    } else if (body.email && body.code) {
      const user = await getUserByEmail(normalizeEmail(body.email));
      if (!user) throw badRequest('invalid_code', 'That code is not valid.');
      const row = await verifyCodeFor(user.id, body.code);
      if (!row) throw badRequest('invalid_code', 'That code is not valid or has expired.');
      await query('update email_tokens set used_at = now() where id = $1', [row.id]);
      userId = user.id;
    } else {
      throw badRequest('missing_fields', 'Provide the code (with email) or the verification link token.');
    }

    await query('update users set email_verified_at = coalesce(email_verified_at, now()), updated_at = now() where id = $1', [
      userId,
    ]);
    const user = await getUserById(userId);
    const session = await createSession(userId, req.headers['user-agent']);
    res.json({
      ...session,
      needsUsername: !user.username,
      usernameIdeas: usernameIdeas(user.email, user.display_name),
      message: 'Email verified. Choose your username to finish setting up.',
    });
  }),
);

router.post(
  '/resend-verification',
  rateLimit({ limit: 5, windowMs: 15 * 60 * 1000, keyPrefix: 'resend' }),
  asyncRoute(async (req, res) => {
    const { email } = z.object({ email: emailSchema }).parse(req.body);
    const user = await getUserByEmail(normalizeEmail(email));
    if (!user || user.email_verified_at) {
      return res.json({ status: 'sent', message: 'If that account needs verification, a code is on its way.' });
    }
    const code = randomCode(6);
    await query('delete from email_tokens where user_id = $1 and purpose = $2', [user.id, 'verify_email']);
    const token = await createEmailToken(user.id, 'verify_email', 30);
    await query(
      `insert into email_tokens (id, user_id, token_hash, purpose, expires_at)
       values ($1, $2, $3, 'verify_email', now() + interval '30 minutes')`,
      [uuid(), user.id, `code:${code}:${user.id}`],
    );
    await sendVerificationEmail(user.email, code, verificationUrl(token));
    return res.json({
      status: 'sent',
      message: 'Verification code sent.',
      devCode: env.ALLOW_DEV_CODES ? code : undefined,
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Google sign in
 * ------------------------------------------------------------------ */

router.post(
  '/google',
  rateLimit({ limit: 20, windowMs: 15 * 60 * 1000, keyPrefix: 'google' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        idToken: z.string().min(20),
        inviteCode: z.string().trim().max(64).optional(),
      })
      .parse(req.body);
    if (!env.GOOGLE_CLIENT_IDS.length) {
      throw new ApiError(503, 'google_signin_not_configured', 'Google sign-in is not configured on the server yet.');
    }
    const google = await verifyGoogleIdToken(body.idToken);
    let user = (await query('select * from users where google_sub = $1', [google.sub])).rows[0];
    if (!user) user = await getUserByEmail(google.email);

    if (!user) {
      const gate = await checkBetaAccess(google.email, body.inviteCode);
      if (!gate.allowed) throw new ApiError(403, gate.reason || 'beta_closed', gate.message || 'Registration is restricted.');
      const userId = uuid();
      await query(
        `insert into users (id, email, email_verified_at, google_sub, display_name, created_at, updated_at)
         values ($1, $2, $3, $4, $5, now(), now())`,
        [
          userId,
          google.email,
          google.emailVerified ? new Date() : null,
          google.sub,
          google.name || google.email.split('@')[0],
        ],
      );
      await consumeInvite({ inviteId: gate.inviteId, code: gate.code, email: google.email });
      user = await getUserById(userId);
    } else {
      await query(
        `update users set google_sub = coalesce(google_sub, $2),
                          email_verified_at = coalesce(email_verified_at, $3),
                          updated_at = now()
          where id = $1`,
        [user.id, google.sub, google.emailVerified ? new Date() : null],
      );
      if (user.deleted_at) throw new ApiError(403, 'account_deleted', 'This account was deleted.');
    }

    const session = await createSession(user.id, req.headers['user-agent']);
    res.json({
      ...session,
      needsUsername: !user.username,
      usernameIdeas: usernameIdeas(user.email, user.display_name),
    });
  }),
);

/* ------------------------------------------------------------------ *
 * Login / refresh / logout
 * ------------------------------------------------------------------ */

router.post(
  '/login',
  rateLimit({ limit: 20, windowMs: 15 * 60 * 1000, keyPrefix: 'login' }),
  asyncRoute(async (req, res) => {
    const body = z.object({ email: emailSchema, password: z.string().min(1).max(200) }).parse(req.body);
    const user = await getUserByEmail(normalizeEmail(body.email));
    // Constant-ish work whether or not the account exists.
    const ok = user ? await verifyPassword(body.password, user.password_hash) : await verifyPassword(body.password, 'scrypt$16384$8$1$AAAA$AAAA');
    if (!user || !ok) throw unauthorized('invalid_credentials', 'Email or password is incorrect.');
    if (user.deleted_at) throw new ApiError(403, 'account_deleted', 'This account was deleted.');
    if (!user.email_verified_at) {
      throw new ApiError(403, 'email_not_verified', 'Verify your email before signing in.', { canResend: true });
    }
    const session = await createSession(user.id, req.headers['user-agent']);
    res.json({
      ...session,
      needsUsername: !user.username,
      usernameIdeas: usernameIdeas(user.email, user.display_name),
    });
  }),
);

router.post(
  '/refresh',
  rateLimit({ limit: 120, windowMs: 15 * 60 * 1000, keyPrefix: 'refresh' }),
  asyncRoute(async (req, res) => {
    const { refreshToken } = z.object({ refreshToken: z.string().min(10) }).parse(req.body);
    const rotated = await rotateRefreshToken(refreshToken, req.headers['user-agent']);
    const user = await getUserById(rotated.userId);
    if (!user || user.deleted_at) throw unauthorized('account_deleted', 'This account is no longer active.');
    res.json({
      accessToken: signAccessToken(user.id),
      refreshToken: rotated.refresh.token,
      tokenType: 'Bearer',
      expiresIn: env.ACCESS_TOKEN_TTL,
      user: selfUser(user),
      needsUsername: !user.username,
    });
  }),
);

router.post(
  '/logout',
  asyncRoute(async (req, res) => {
    const token = req.body?.refreshToken;
    if (token) await revokeRefreshToken(token);
    res.json({ status: 'logged_out' });
  }),
);

router.post(
  '/logout-all',
  requireAuth,
  asyncRoute(async (req, res) => {
    await revokeAllSessions(req.userId);
    res.json({ status: 'logged_out_everywhere' });
  }),
);

/* ------------------------------------------------------------------ *
 * Password reset
 * ------------------------------------------------------------------ */

router.post(
  '/password/forgot',
  rateLimit({ limit: 5, windowMs: 15 * 60 * 1000, keyPrefix: 'forgot' }),
  asyncRoute(async (req, res) => {
    const { email } = z.object({ email: emailSchema }).parse(req.body);
    const user = await getUserByEmail(normalizeEmail(email));
    if (user && !user.deleted_at) {
      const code = randomCode(6);
      await query('delete from email_tokens where user_id = $1 and purpose = $2', [user.id, 'reset_password']);
      const token = await createEmailToken(user.id, 'reset_password', 30);
      await query(
        `insert into email_tokens (id, user_id, token_hash, purpose, expires_at)
         values ($1, $2, $3, 'reset_password', now() + interval '30 minutes')`,
        [uuid(), user.id, `code:${code}:${user.id}`],
      );
      const mail = await sendPasswordResetEmail(user.email, code, resetUrl(token));
      return res.json({
        status: 'sent',
        emailDelivered: mail.delivered,
        message: 'If that email has an account, a reset code is on its way.',
        devCode: env.ALLOW_DEV_CODES ? code : undefined,
      });
    }
    return res.json({ status: 'sent', message: 'If that email has an account, a reset code is on its way.' });
  }),
);

router.post(
  '/password/reset',
  rateLimit({ limit: 10, windowMs: 15 * 60 * 1000, keyPrefix: 'reset' }),
  asyncRoute(async (req, res) => {
    const body = z
      .object({
        email: emailSchema.optional(),
        code: z.string().trim().min(4).max(12).optional(),
        token: z.string().trim().min(10).optional(),
        newPassword: passwordSchema,
      })
      .parse(req.body);

    let userId = null;
    if (body.token) {
      const consumed = await consumeEmailToken(body.token, 'reset_password');
      if (!consumed) throw badRequest('invalid_token', 'That reset link is invalid or has expired.');
      userId = consumed.userId;
    } else if (body.email && body.code) {
      const user = await getUserByEmail(normalizeEmail(body.email));
      if (!user) throw badRequest('invalid_code', 'That reset code is not valid.');
      const { rows } = await query(
        `select id from email_tokens
          where user_id = $1 and purpose = 'reset_password' and token_hash = $2
            and used_at is null and expires_at > now()
          order by created_at desc limit 1`,
        [user.id, `code:${body.code}:${user.id}`],
      );
      if (!rows[0]) throw badRequest('invalid_code', 'That reset code is not valid or has expired.');
      await query('update email_tokens set used_at = now() where id = $1', [rows[0].id]);
      userId = user.id;
    } else {
      throw badRequest('missing_fields', 'Provide the code (with email) or the reset link token.');
    }

    await query('update users set password_hash = $2, updated_at = now() where id = $1', [
      userId,
      await hashPassword(body.newPassword),
    ]);
    // Any stolen refresh token dies with the password change.
    await revokeAllSessions(userId);
    const user = await getUserById(userId);
    const session = await createSession(userId, req.headers['user-agent']);
    res.json({ ...session, needsUsername: !user.username, message: 'Password updated.' });
  }),
);

/* ------------------------------------------------------------------ *
 * Session / bootstrap
 * ------------------------------------------------------------------ */

router.get(
  '/me',
  requireAuth,
  asyncRoute(async (req, res) => {
    res.json(await bootstrap(req.userId));
  }),
);

router.get('/dev/last-emails', (req, res) => {
  if (!env.ALLOW_DEV_CODES) return res.status(404).json({ error: { code: 'not_found', message: 'Not found' } });
  return res.json({ mails: recentMails(10) });
});

/* ------------------------------------------------------------------ *
 * Username allocation
 * ------------------------------------------------------------------ */

router.get(
  '/username-rules',
  (req, res) => {
    res.json({
      minLength: 3,
      maxLength: 20,
      pattern: '^[a-z][a-z0-9._]*$',
      rules: [
        '3-20 characters',
        'lowercase letters, numbers, underscores and periods only',
        'must start with a letter',
        'no two periods in a row',
        'cannot end with a period',
        'no reserved or offensive words',
      ],
      changeCooldownDays: env.USERNAME_CHANGE_COOLDOWN_DAYS,
      reuseCooldownDays: env.USERNAME_REUSE_COOLDOWN_DAYS,
      profileUrlFormat: 'https://worldfriends.app/@username',
    });
  },
);

export default router;
