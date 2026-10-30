import http from 'node:http';
import { env, requireProdConfig } from './env.js';
import { createApp } from './app.js';
import { initRealtime, closeRealtime } from './realtime.js';
import { closePool, query } from './db.js';
import { startJobs } from './jobs.js';

const app = createApp();
const server = http.createServer(app);
initRealtime(server);

const stopJobs = startJobs();

server.listen(env.PORT, env.HOST, () => {
  console.log(`[api] WorldFriends API listening on http://${env.HOST}:${env.PORT} (env=${env.NODE_ENV})`);
  console.log(`[api] websocket endpoint ws://${env.HOST}:${env.PORT}/ws`);
  const problems = requireProdConfig();
  for (const problem of problems) console.warn(`[config] ${problem}`);
  if (!env.SMTP_URL) console.warn('[config] SMTP_URL not set: verification emails will be logged, not delivered.');
  if (!env.DEEPL_API_KEY && !env.GOOGLE_TRANSLATE_API_KEY) {
    console.warn('[config] No translation provider configured: /v1/translate returns 503.');
  }
  query('select 1')
    .then(() => console.log('[api] database connection ok'))
    .catch((err) => console.error('[api] database connection FAILED:', err.message));
});

async function shutdown(signal) {
  console.log(`[api] ${signal} received, shutting down`);
  stopJobs();
  server.close();
  await closeRealtime().catch(() => {});
  await closePool().catch(() => {});
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (err) => {
  console.error('[api] unhandled rejection', err);
});
