/**
 * Register authenticated IDIR users in GeoServer's default user/group service so
 * they appear under Security → Users/Groups in the web UI (and can be assigned
 * roles/groups by an admin). The username registered is the proxy principal
 * (sec-username = lower-cased email), so the UI list is human-identifiable.
 *
 * Roles are resolved separately by GeoServer's role service; this is
 * presentation/management only. Fire-and-forget; disabled unless
 * GEOSERVER_ADMIN_PASSWORD is set. Calls the same internal gateway the proxy
 * forwards to (config.gateway.origin), honouring GATEWAY_TLS_INSECURE.
 *
 * DEBUG: logs whether the feature is enabled, the preload result, and every
 * REST call's method/URL/status. A 401/403 here usually means GEOSERVER_ADMIN_*
 * is wrong; a non-2xx on POST means the user/group service isn't the one the UI
 * reads from.
 */
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { config } from './config.ts';
import { logger } from './logger.ts';

/** Principals known to exist in the service (preloaded + created this process). */
const known = new Set<string>();
let preloaded = false;

function usersUrl(): string {
  const gs = config.geoserver;
  return `${config.gateway.origin}${gs.basePath}/rest/security/usergroup/service/${gs.serviceName}/users`;
}

interface GsResponse {
  status: number;
  body: string;
}

/** Minimal admin REST call to the internal gateway (no external deps). */
function gsRequest(method: string, urlStr: string, payload?: string): Promise<GsResponse> {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const isHttps = url.protocol === 'https:';
    const transport = isHttps ? https : http;

    const headers: Record<string, string> = {
      Authorization:
        'Basic ' +
        Buffer.from(`${config.geoserver.adminUser}:${config.geoserver.adminPassword}`).toString('base64'),
      Accept: 'application/json',
    };
    if (payload !== undefined) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = String(Buffer.byteLength(payload));
    }

    const req = transport.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search,
        method,
        headers,
        ...(isHttps ? { rejectUnauthorized: !config.gateway.tlsInsecure } : {}),
      },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          if (body.length < 1_000_000) body += chunk; // cap defensively
        });
        res.on('end', () => {
          logger.debug(
            { ev: 'geoserver:rest', method, path: url.pathname, status: res.statusCode ?? 0 },
            'GeoServer admin REST call complete',
          );
          resolve({ status: res.statusCode ?? 0, body });
        });
      },
    );
    req.setTimeout(config.geoserver.timeoutMs, () => req.destroy(new Error('geoserver request timeout')));
    req.on('error', reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

/** Load the existing user list once so we don't POST duplicates every login. */
async function preload(): Promise<void> {
  if (preloaded) return;
  try {
    const { status, body } = await gsRequest('GET', `${usersUrl()}.json`);
    if (status >= 200 && status < 300 && body) {
      // GeoServer's JSON/XML serialization is inconsistent across versions —
      // extract userName values from whichever shape came back.
      for (const m of body.matchAll(/"userName"\s*:\s*"([^"]+)"/g)) if (m[1]) known.add(m[1].toLowerCase());
      for (const m of body.matchAll(/<userName>([^<]+)<\/userName>/g)) if (m[1]) known.add(m[1].toLowerCase());
      preloaded = true;
      logger.info(
        { ev: 'geoserver:preload-ok', status, knownUsers: known.size },
        'preloaded existing GeoServer user/group users',
      );
    } else {
      logger.warn(
        { ev: 'geoserver:preload-nonok', status },
        'GeoServer user preload returned non-2xx; check GEOSERVER_ADMIN_* and the user/group service name',
      );
    }
  } catch (err) {
    logger.debug({ ev: 'geoserver:preload-error', err: (err as Error).message }, 'GeoServer user preload failed; will retry');
  }
}

/**
 * Ensure a user (principal/email) exists in the default user/group service.
 * Fire-and-forget — caller should `void` this and never await on the hot path.
 */
export async function ensureGeoServerUser(principal: string): Promise<void> {
  const gs = config.geoserver;
  if (!gs.adminPassword || !principal) {
    logger.debug(
      { ev: 'geoserver:ensure-skip', reason: !gs.adminPassword ? 'feature-disabled' : 'no-principal', principal: principal || null },
      'ensureGeoServerUser skipped',
    );
    return; // feature off / nothing to do
  }

  const key = principal.toLowerCase();
  await preload();
  if (known.has(key)) {
    logger.debug({ ev: 'geoserver:ensure-known', principal }, 'IDIR user already registered (cached)');
    return;
  }

  const payload = JSON.stringify({
    user: {
      userName: principal,
      password: crypto.randomBytes(24).toString('base64url'), // never used (header pre-auth)
      enabled: true,
    },
  });

  try {
    const { status } = await gsRequest('POST', usersUrl(), payload);
    if (status >= 200 && status < 300) {
      known.add(key);
      logger.info({ ev: 'geoserver:ensure-ok', principal, status }, 'registered IDIR user in GeoServer user/group service');
    } else if (status === 409 || status === 500) {
      // GeoServer returns 409/500 when the user already exists — treat as done.
      known.add(key);
      logger.info({ ev: 'geoserver:ensure-exists', principal, status }, 'IDIR user already present in GeoServer');
    } else {
      logger.warn({ ev: 'geoserver:ensure-nonok', principal, status }, 'GeoServer user registration returned unexpected status');
    }
  } catch (err) {
    logger.warn(
      { ev: 'geoserver:ensure-error', err: (err as Error).message, principal },
      'GeoServer user registration failed (non-fatal)',
    );
  }
}
