import nodemailer from 'nodemailer';
import { env } from './env.js';

let transporter = null;
if (env.SMTP_URL) {
  transporter = nodemailer.createTransport(env.SMTP_URL);
}

/** Ring buffer of recently "sent" mails, so dev/test builds can read codes. */
const recent = [];
export function recentMails(limit = 10) {
  return recent.slice(-limit).reverse();
}

function remember(mail) {
  recent.push({ ...mail, at: new Date().toISOString() });
  if (recent.length > 50) recent.shift();
}

async function deliver({ to, subject, text, html }) {
  remember({ to, subject, text });
  if (!transporter) {
    console.log(`[mail] (no SMTP configured) to=${to} subject="${subject}"\n${text}`);
    return { delivered: false, reason: 'smtp_not_configured' };
  }
  try {
    await transporter.sendMail({ from: env.MAIL_FROM, to, subject, text, html });
    return { delivered: true };
  } catch (err) {
    console.error('[mail] send failed', err.message);
    return { delivered: false, reason: 'send_failed' };
  }
}

export function sendVerificationEmail(to, code, link) {
  return deliver({
    to,
    subject: `Your WorldFriends code: ${code}`,
    text: [
      'Welcome to the WorldFriends private beta!',
      '',
      `Your verification code is ${code}.`,
      `Or tap this link to verify: ${link}`,
      '',
      'The code expires in 30 minutes. If you did not sign up, ignore this email.',
    ].join('\n'),
    html: `<p>Welcome to the <strong>WorldFriends</strong> private beta!</p>
           <p>Your verification code is <strong style="font-size:22px;letter-spacing:3px">${code}</strong></p>
           <p><a href="${link}">Verify my email</a> (expires in 30 minutes)</p>`,
  });
}

export function sendPasswordResetEmail(to, code, link) {
  return deliver({
    to,
    subject: `Reset your WorldFriends password (code ${code})`,
    text: [
      'Someone asked to reset the password for this account.',
      '',
      `Reset code: ${code}`,
      `Or tap this link: ${link}`,
      '',
      'The code expires in 30 minutes. If this was not you, you can ignore this email.',
    ].join('\n'),
    html: `<p>Reset code: <strong style="font-size:22px;letter-spacing:3px">${code}</strong></p>
           <p><a href="${link}">Choose a new password</a> (expires in 30 minutes)</p>`,
  });
}
