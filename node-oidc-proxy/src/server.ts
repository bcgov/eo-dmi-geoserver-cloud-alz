/**
 * Process entry point. Run OIDC discovery first (fail fast if Keycloak is
 * unreachable or misconfigured), then start listening on 0.0.0.0:$PORT.
 */
import { config } from './config.ts';
import { logger } from './logger.ts';
import { initOidc } from './oidc.ts';
import { createApp } from './app.ts';

/**
 * Dump the EFFECTIVE (non-secret) configuration at boot. This is the single
 * fastest way to catch a misconfiguration — e.g. the principal claim is `email`
 * but the identity header is mis-named, the gateway origin is wrong, or the DB /
 * GeoServer-admin features are silently disabled because an env var is blank.
 */
function logEffectiveConfig(): void {
  logger.info(
    {
      ev: 'boot:config',
      port: config.port,
      logLevel: config.logLevel,
      debug: config.debug,
      oidc: {
        issuer: config.oidc.issuer,
        clientId: config.oidc.clientId,
        redirectUri: config.oidc.redirectUri,
        postLogoutRedirectUri: config.oidc.postLogoutRedirectUri || null,
        scopes: config.oidc.scopes,
        clientSecretSet: config.oidc.clientSecret.length > 0,
      },
      identity: {
        identityHeader: config.identityHeader,
        usernameClaim: config.usernameClaim,
        usernameLowercase: config.usernameLowercase,
        userGuidClaim: config.userGuidClaim,
        displayNameHeader: config.displayNameHeader,
        displayNameClaim: config.displayNameClaim,
      },
      gateway: {
        origin: config.gateway.origin,
        tlsInsecure: config.gateway.tlsInsecure,
        connectTimeoutMs: config.gateway.connectTimeoutMs,
        readTimeoutMs: config.gateway.readTimeoutMs,
      },
      publicOrigin: config.publicOrigin,
      session: {
        cookieName: config.session.cookieName,
        maxAgeSeconds: config.session.maxAgeSeconds,
        secretSet: config.session.secret.length > 0,
      },
      machineAuthPassthrough: config.machineAuthPassthrough,
      defaultReturnTo: config.defaultReturnTo,
      dbConfigured: !!(config.db.host && config.db.database && config.db.username && config.db.password),
      geoserverAdminConfigured: !!config.geoserver.adminPassword,
      geoserver: {
        adminUser: config.geoserver.adminUser,
        basePath: config.geoserver.basePath,
        serviceName: config.geoserver.serviceName,
      },
      adminPrincipals: config.adminPrincipals,
    },
    'boot:config — effective configuration',
  );
}

async function main(): Promise<void> {
  logEffectiveConfig();

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
