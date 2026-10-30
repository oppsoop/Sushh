/** Error type that maps 1:1 onto an API response. */
export class ApiError extends Error {
  constructor(status, code, message, details) {
    super(message || code);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export const badRequest = (code, message, details) => new ApiError(400, code, message, details);
export const unauthorized = (code = 'unauthorized', message = 'Authentication required') =>
  new ApiError(401, code, message);
export const forbidden = (code = 'forbidden', message = 'Not allowed') => new ApiError(403, code, message);
export const notFound = (code = 'not_found', message = 'Not found') => new ApiError(404, code, message);
export const conflict = (code, message, details) => new ApiError(409, code, message, details);
export const tooMany = (message = 'Too many requests') => new ApiError(429, 'rate_limited', message);
export const unavailable = (code, message, details) => new ApiError(503, code, message, details);

// eslint-disable-next-line no-unused-vars
export function errorHandler(err, req, res, next) {
  if (err instanceof ApiError) {
    return res.status(err.status).json({
      error: { code: err.code, message: err.message, details: err.details ?? undefined },
    });
  }
  if (err && err.name === 'ZodError') {
    return res.status(400).json({
      error: {
        code: 'validation_error',
        message: 'Invalid request',
        details: err.issues?.map((i) => ({ path: i.path.join('.'), message: i.message })),
      },
    });
  }
  if (err && err.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({ error: { code: 'file_too_large', message: 'Upload too large' } });
  }
  if (err && (err.type === 'entity.parse.failed' || err.status === 400)) {
    return res.status(400).json({ error: { code: 'bad_json', message: 'Malformed request body' } });
  }
  console.error('[api] unhandled error', err);
  return res.status(500).json({ error: { code: 'internal_error', message: 'Something went wrong' } });
}

/** Wrap async route handlers so rejected promises reach errorHandler. */
export const asyncRoute = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
