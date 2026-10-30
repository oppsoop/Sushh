import express from 'express';
import cors from 'cors';
import { env } from './env.js';
import { ApiError, errorHandler } from './errors.js';
import { rateLimit } from './ratelimit.js';

import authRoutes from './routes/auth.js';
import usernameRoutes from './routes/username.js';
import userRoutes from './routes/users.js';
import chatRoutes from './routes/chat.js';
import mediaRoutes, { storiesRouter } from './routes/media.js';
import socialRoutes from './routes/social.js';
import miscRoutes from './routes/misc.js';

export function createApp() {
  const app = express();

  app.set('trust proxy', env.TRUST_PROXY);
  app.disable('x-powered-by');

  app.use(
    cors({
      origin: env.CORS_ORIGINS.includes('*') ? true : env.CORS_ORIGINS,
      credentials: false,
      allowedHeaders: ['Authorization', 'Content-Type', 'X-Client-Message-Id', 'X-Admin-Token'],
      methods: ['GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'],
    }),
  );

  app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    const started = Date.now();
    res.on('finish', () => {
      if (req.path === '/v1/health') return;
      const ms = Date.now() - started;
      console.log(`${req.method} ${req.path} ${res.statusCode} ${ms}ms`);
    });
    next();
  });

  app.use(express.json({ limit: '2mb' }));
  app.use(express.urlencoded({ extended: true, limit: '2mb' }));

  // Coarse global shield; per-route limiters tighten the sensitive paths.
  app.use('/v1', rateLimit({ limit: 600, windowMs: 60 * 1000, keyPrefix: 'global' }));

  app.get('/', (req, res) => {
    res.json({ service: 'worldfriends-api', version: '1.0.0', docs: '/v1/health' });
  });

  app.use('/v1/auth', authRoutes);
  app.use('/v1/username', usernameRoutes);
  app.use('/v1', userRoutes);
  app.use('/v1', chatRoutes);
  app.use('/v1', mediaRoutes);
  app.use('/v1', storiesRouter);
  app.use('/v1', socialRoutes);
  app.use('/v1', miscRoutes);

  app.use((req, res, next) => next(new ApiError(404, 'not_found', `No route for ${req.method} ${req.path}`)));
  app.use(errorHandler);

  return app;
}
