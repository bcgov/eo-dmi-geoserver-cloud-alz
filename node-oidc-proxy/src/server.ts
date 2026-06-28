/**
 * Process entry point. Run OIDC discovery first (fail fast if Keycloak is
 * unreachable or misconfigured), then start listening on 0.0.0.0:$PORT.
 */
import { config } from './config.ts';
import { logger } from './logger.ts';
import { initOidc } from './oidc.ts';
import { createApp } from './app.ts';

async function main(): Promise<void> {
  await initOidc();

  const app = createApp();
  const server = app.listen(config.port, '0.0.0.0', () => {
    logger.info({ port: config.port }, 'node-oidc-edge-proxy listening');
  });

  // Graceful shutdown for container orchestration (SIGTERM from App Service).
  const shutdown = (signal: string): void => {
    logger.info({ signal }, 'shutting down');
    server.close(() => process.exit(0));
    // Hard cap so a hung connection can't block termination forever.
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err: unknown) => {
  logger.fatal({ err: (err as Error).message }, 'fatal startup error');
  process.exit(1);
});
