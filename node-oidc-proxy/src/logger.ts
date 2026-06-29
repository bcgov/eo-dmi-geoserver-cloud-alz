/**
 * Structured JSON logger (pino). Container stdout is the log sink.
 *
 * Tokens and secrets must never be logged (contract §6, §10). We both avoid
 * passing them into log calls AND configure redaction as a backstop.
 *
 * NOTE on debug mode: the verbose header logging in debug.ts already masks
 * secret values itself (and logs under its own keys, e.g. `headers.cookie`
 * summaries — not `req.headers.cookie`). The pino `redact` list below is an
 * independent backstop for any *accidental* logging of the raw request/response
 * objects. When DEBUG_UNSAFE_HEADERS=true we disable that backstop so a
 * deliberately-unsafe test run can surface raw values end-to-end.
 */
import pino from 'pino';
import { config } from './config.ts';

const REDACT_PATHS = [
  'req.headers.authorization',
  'req.headers.cookie',
  'res.headers["set-cookie"]',
  'access_token',
  'refresh_token',
  'id_token',
  '*.access_token',
  '*.refresh_token',
  '*.id_token',
];

export const logger = pino({
  level: config.logLevel,
  // Unsafe mode (controlled test only) turns the backstop off entirely.
  redact: config.debug.unsafe
    ? { paths: [], censor: '[redacted]' }
    : { paths: REDACT_PATHS, censor: '[redacted]' },
  // Stable field names; timestamps in epoch millis for easy ingestion.
  base: { service: 'node-oidc-edge-proxy' },
});

if (config.debug.unsafe) {
  logger.warn(
    'DEBUG_UNSAFE_HEADERS=true — raw cookie/token values WILL be logged. Use for a private test run only, then turn it off.',
  );
}
