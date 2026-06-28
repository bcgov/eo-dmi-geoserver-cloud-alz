/**
 * Structured JSON logger (pino). Container stdout is the log sink.
 *
 * Tokens and secrets must never be logged (contract §6, §10). We both avoid
 * passing them into log calls AND configure redaction as a backstop.
 */
import pino from 'pino';
import { config } from './config.ts';

export const logger = pino({
  level: config.logLevel,
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      'res.headers["set-cookie"]',
      'access_token',
      'refresh_token',
      'id_token',
      '*.access_token',
      '*.refresh_token',
      '*.id_token',
    ],
    censor: '[redacted]',
  },
  // Stable field names; timestamps in epoch millis for easy ingestion.
  base: { service: 'node-oidc-edge-proxy' },
});
