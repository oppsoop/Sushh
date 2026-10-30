import { env } from './env.js';
import { query } from './db.js';
import { ApiError } from './errors.js';

/**
 * Beta gate.
 *
 * Registration is allowed when:
 *  - BETA_MODE is off, or
 *  - the email is in BETA_ALLOWED_EMAILS, or
 *  - the email has an unused row in beta_invites, or
 *  - a valid invite code is supplied (env list or beta_invites), or
 *  - BETA_ALLOW_ANY_EMAIL is on (open beta).
 */
export async function checkBetaAccess(email, inviteCode) {
  const normalizedEmail = String(email || '').trim().toLowerCase();
  if (!env.BETA_MODE) return { allowed: true, reason: 'beta_disabled' };
  if (env.BETA_ALLOW_ANY_EMAIL) return { allowed: true, reason: 'open_beta' };
  if (env.BETA_ALLOWED_EMAILS.includes(normalizedEmail)) {
    return { allowed: true, reason: 'email_allowlist' };
  }

  if (inviteCode) {
    const code = String(inviteCode).trim();
    if (env.BETA_INVITE_CODES.includes(code)) return { allowed: true, reason: 'env_invite', code };
    const { rows } = await query(
      `select id, email, max_uses, used_count, expires_at, revoked_at
         from beta_invites where code = $1`,
      [code],
    );
    const invite = rows[0];
    if (invite) {
      const expired = invite.expires_at && new Date(invite.expires_at).getTime() < Date.now();
      const emailMatches = !invite.email || invite.email.toLowerCase() === normalizedEmail;
      if (!invite.revoked_at && !expired && emailMatches && invite.used_count < invite.max_uses) {
        return { allowed: true, reason: 'invite_code', code, inviteId: invite.id };
      }
    }
    return { allowed: false, reason: 'invite_invalid', message: 'That invite code is not valid any more.' };
  }

  const { rows } = await query(
    `select id from beta_invites
      where lower(email) = $1 and revoked_at is null
        and (expires_at is null or expires_at > now())
        and used_count < max_uses
      limit 1`,
    [normalizedEmail],
  );
  if (rows[0]) return { allowed: true, reason: 'email_invite', inviteId: rows[0].id };

  return {
    allowed: false,
    reason: 'beta_closed',
    message: 'WorldFriends is in a private beta. Ask the owner to add your email or send you an invite code.',
  };
}

export async function consumeInvite({ inviteId, code, email, client }) {
  const run = client?.query.bind(client) || query;
  if (inviteId) {
    // Atomic quota enforcement: only one concurrent signup can consume the
    // last available use. This is committed with the new account.
    const result = await run(
      `update beta_invites set used_count = used_count + 1
        where id = $1 and revoked_at is null and used_count < max_uses
          and (expires_at is null or expires_at > now())
          and (email is null or lower(email) = lower($2)) returning id`,
      [inviteId, email],
    );
    if (!result.rowCount) throw new ApiError(403, 'invite_invalid', 'That invite code is not valid any more.');
    return;
  }
  if (code && !env.BETA_INVITE_CODES.includes(code)) {
    throw new ApiError(403, 'invite_invalid', 'That invite code is not valid any more.');
  }
}

export async function betaConfig() {
  const { rows } = await query('select count(*)::int as n from beta_invites where revoked_at is null');
  return {
    betaMode: env.BETA_MODE,
    showBetaBadge: env.BETA_MODE,
    allowAnyEmail: env.BETA_ALLOW_ANY_EMAIL,
    allowedEmailCount: env.BETA_ALLOWED_EMAILS.length,
    inviteCount: rows[0]?.n ?? 0,
    message: env.BETA_MODE
      ? 'Private friends-and-family beta. An invite may be required.'
      : 'Open registration',
  };
}

export async function addInvite({ code, email, note, maxUses = 1, expiresAt = null }) {
  const { rows } = await query(
    `insert into beta_invites (id, code, email, note, max_uses, expires_at)
     values (gen_random_uuid(), $1, $2, $3, $4, $5)
     on conflict (code) do update set note = excluded.note, max_uses = excluded.max_uses
     returning id, code, email, note, max_uses, used_count, expires_at`,
    [code, email ? String(email).toLowerCase() : null, note || null, maxUses, expiresAt],
  );
  return rows[0];
}
