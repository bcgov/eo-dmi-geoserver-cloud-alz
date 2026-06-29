/**
 * Express wiring: health, the three /auth/* endpoints, the admin reference view,
 * an optional "/" courtesy redirect, and the catch-all that applies the session /
 * unauthenticated decision matrix (contract §2, §5) before reverse-proxying.
 */
import express, { type Request, type Response } from 'express';
import { config } from './config.ts';
import { logger } from './logger.ts';
import {
  readSession,
  sealSession,
  writeSessionCookie,
  clearSessionCookie,
  type SessionData,
} from './session.ts';
import { beginLogin, completeLogin, refresh, buildLogoutUrl, clearTxCookie } from './oidc.ts';
import { proxy } from './proxy.ts';
import { upsertUser, listUsers } from './db.ts';
import { ensureGeoServerUser } from './geoserver.ts';
import { requestLogging, getReqId } from './debug.ts';

/** Refresh when the access token has less than this many seconds left. */
const REFRESH_SKEW_SECONDS = 30;

/**
 * Only allow same-origin redirect targets (must be an absolute path, not a
 * protocol-relative "//evil.com" or an absolute URL) — prevents open redirects.
 */
function safePath(value: string | undefined, fallback: string): string {
  if (typeof value !== 'string') return fallback;
  if (!value.startsWith('/') || value.startsWith('//')) return fallback;
  return value;
}

function wantsHtml(req: Request): boolean {
  return (req.headers.accept ?? '').includes('text/html');
}

function hasMachineAuth(req: Request): boolean {
  const auth = req.headers.authorization ?? '';
  if (auth.toLowerCase().startsWith('basic ')) return true;
  return typeof req.query.authkey === 'string' && req.query.authkey !== '';
}

/** Escape untrusted text before embedding in the admin HTML table. */
function esc(value: string): string {
  return value.replace(/[&<>"']/g, (c) =>
    c === '&' ? '&amp;' : c === '<' ? '&lt;' : c === '>' ? '&gt;' : c === '"' ? '&quot;' : '&#39;',
  );
}

export function createApp(): express.Express {
  const app = express();

  // App Service / Front Door terminates TLS in front of us.
  app.set('trust proxy', true);
  app.disable('x-powered-by');

  // --- Global request/response header logging (hops 1 & 4) ----------------
  // First middleware so it covers EVERY route — auth endpoints and proxied
  // traffic alike. Logs sanitised inbound + final headers with a reqId.
  app.use(requestLogging());

  // --- Health check (no proxy, no auth) -----------------------------------
  app.get('/healthz', (_req, res) => {
    res.status(200).json({ status: 'ok' });
  });

  // --- OIDC: begin login --------------------------------------------------
  app.get('/auth/login', async (req, res) => {
    const reqId = getReqId(req);
    try {
      const returnTo = safePath(
        typeof req.query.returnTo === 'string' ? req.query.returnTo : undefined,
        config.defaultReturnTo,
      );
      const url = await beginLogin(res, returnTo);
      logger.info(
        { reqId, ev: 'auth:login-begin', returnTo, authorizeHost: safeHost(url) },
        'auth:login — redirecting to Keycloak authorize',
      );
      res.redirect(302, url);
    } catch (err) {
      logger.error({ reqId, ev: 'auth:login-error', err: (err as Error).message }, 'login initiation failed');
      res.status(500).json({ error: 'login_failed' });
    }
  });

  // --- OIDC: callback (the registered redirect URI) -----------------------
  app.get('/auth/callback', async (req, res) => {
    const reqId = getReqId(req);
    logger.info(
      {
        reqId,
        ev: 'auth:callback-received',
        hasCode: typeof req.query.code === 'string',
        hasState: typeof req.query.state === 'string',
        hasError: typeof req.query.error === 'string',
        oidcError: typeof req.query.error === 'string' ? req.query.error : null,
        oidcErrorDescription:
          typeof req.query.error_description === 'string' ? req.query.error_description : null,
        hasTxCookie: !!req.headers.cookie?.includes(`${config.session.cookieName}_tx`),
      },
      'auth:callback — received from Keycloak',
    );
    try {
      const result = await completeLogin(req);
      const session: SessionData = {
        sub: result.sub,
        username: result.username,
        displayName: result.displayName,
        accessExp: result.accessExp,
        refreshToken: result.refreshToken,
        idToken: result.idToken,
      };
      logger.info(
        {
          reqId,
          ev: 'auth:callback-success',
          principal: result.username, // shown in full — this becomes sec-username
          hasGuid: !!result.guid,
          hasDisplayName: !!result.displayName,
          displayName: result.displayName ?? null,
          accessExp: result.accessExp,
          returnTo: result.returnTo,
        },
        'auth:callback — session established',
      );
      // Auto-register the user (fire-and-forget; never block the OIDC callback):
      //  1. upsertUser → gssec.user_display_names (GUID + email + display name).
      //  2. ensureGeoServerUser → default user/group service (UI visibility), keyed
      //     on the principal (email). No-op unless GEOSERVER_ADMIN_PASSWORD is set.
      void upsertUser(result.guid, result.username, result.displayName);
      void ensureGeoServerUser(result.username);
      writeSessionCookie(res, await sealSession(session));
      clearTxCookie(res);
      res.redirect(302, safePath(result.returnTo, config.defaultReturnTo));
    } catch (err) {
      logger.error({ reqId, ev: 'auth:callback-error', err: (err as Error).message }, 'callback failed');
      clearTxCookie(res);
      res.status(400).json({ error: 'invalid_callback' });
    }
  });

  // --- OIDC: logout -------------------------------------------------------
  app.get('/auth/logout', async (req, res) => {
    const reqId = getReqId(req);
    const session = await readSession(req);
    clearSessionCookie(res);
    clearTxCookie(res);
    logger.info(
      { reqId, ev: 'auth:logout', hadSession: !!session, principal: session?.username ?? null },
      'auth:logout',
    );
    res.redirect(302, buildLogoutUrl(session?.idToken));
  });

  // --- Admin reference view: display name ↔ email ↔ GUID ------------------
  // Gated to principals listed in GEOSERVER_ADMIN_PRINCIPALS. Lets a super admin
  // map the email shown in GeoServer's UI back to the person + stable IDIR GUID.
  app.get('/admin/idir-users', async (req, res) => {
    const session = await readSession(req);
    if (!session) {
      res.redirect(302, `/auth/login?returnTo=${encodeURIComponent(req.originalUrl)}`);
      return;
    }
    if (config.adminPrincipals.length === 0 || !config.adminPrincipals.includes(session.username.toLowerCase())) {
      res.status(403).json({ error: 'forbidden' });
      return;
    }
    try {
      const users = await listUsers();
      if (req.query.format === 'json') {
        res.json(users);
        return;
      }
      const rows = users
        .map(
          (u) =>
            `<tr><td>${esc(u.displayName)}</td><td>${esc(u.email ?? '')}</td><td><code>${esc(u.guid)}</code></td></tr>`,
        )
        .join('');
      res
        .type('html')
        .send(
          `<!doctype html><html><head><meta charset="utf-8"><title>IDIR users</title>` +
            `<style>body{font:14px system-ui,sans-serif;margin:2rem}table{border-collapse:collapse}` +
            `th,td{border:1px solid #ccc;padding:6px 10px;text-align:left}th{background:#f4f4f4}code{font-size:12px}</style>` +
            `</head><body><h1>IDIR users (${users.length})</h1>` +
            `<p>Display name &rarr; email (GeoServer username) &rarr; stable IDIR GUID.</p>` +
            `<table><thead><tr><th>Display name</th><th>Email (GeoServer username)</th><th>IDIR GUID</th></tr></thead>` +
            `<tbody>${rows}</tbody></table></body></html>`,
        );
    } catch (err) {
      logger.error({ err: (err as Error).message }, 'idir-users lookup failed');
      res.status(500).json({ error: 'lookup_failed' });
    }
  });

  // --- Courtesy redirect for the bare root --------------------------------
  app.get('/', (_req, res) => {
    res.redirect(302, config.defaultReturnTo);
  });

  // --- Catch-all: session check → inject + proxy, else decision matrix -----
  app.use((req, res) => {
    void handleProxy(req, res);
  });

  return app;
}

async function handleProxy(req: Request, res: Response): Promise<void> {
  const reqId = getReqId(req);
  let session = await readSession(req);

  // Silent refresh when the access token is at/near expiry (contract §6).
  let refreshed = false;
  if (session && session.accessExp - REFRESH_SKEW_SECONDS <= nowSeconds()) {
    session = await tryRefresh(session, res);
    refreshed = true;
  }

  if (session) {
    logger.info(
      {
        reqId,
        ev: 'handleProxy:authenticated',
        method: req.method,
        path: req.path,
        principal: session.username,
        hasDisplayName: !!session.displayName,
        accessExp: session.accessExp,
        refreshed,
        decision: 'inject+proxy',
      },
      'handleProxy → inject identity + proxy',
    );
    proxy(req, res, session.username, session.displayName);
    return;
  }

  // ---- Unauthenticated decision matrix (§5) ----
  // Rule 2: machine clients (Basic / authkey) pass through WITHOUT injection.
  if (config.machineAuthPassthrough && hasMachineAuth(req)) {
    logger.info(
      { reqId, ev: 'handleProxy:machine-auth', method: req.method, path: req.path, decision: 'passthrough-no-inject' },
      'handleProxy → machine auth passthrough (no identity injected)',
    );
    proxy(req, res, undefined);
    return;
  }
  // Rule 3: browsers get redirected into the OIDC login.
  if (wantsHtml(req)) {
    const returnTo = encodeURIComponent(req.originalUrl);
    logger.info(
      { reqId, ev: 'handleProxy:redirect-login', method: req.method, path: req.path, decision: 'redirect-to-login' },
      'handleProxy → no session, redirecting browser to /auth/login',
    );
    res.redirect(302, `/auth/login?returnTo=${returnTo}`);
    return;
  }
  // Rule 4: API/XHR clients get a 401 (no redirect).
  logger.info(
    { reqId, ev: 'handleProxy:401', method: req.method, path: req.path, decision: '401-unauthenticated' },
    'handleProxy → no session, 401 for non-HTML client',
  );
  res.set('WWW-Authenticate', 'Bearer').status(401).json({ error: 'unauthenticated' });
}

/** Attempt a silent refresh; on failure clear the cookie and de-authenticate. */
async function tryRefresh(session: SessionData, res: Response): Promise<SessionData | null> {
  try {
    const renewed = await refresh(session.refreshToken);
    const next: SessionData = {
      sub: renewed.sub || session.sub,
      username: renewed.username || session.username,
      displayName: renewed.displayName ?? session.displayName,
      accessExp: renewed.accessExp,
      refreshToken: renewed.refreshToken,
      idToken: renewed.idToken ?? session.idToken,
    };
    writeSessionCookie(res, await sealSession(next));
    logger.info(
      { ev: 'auth:refresh-success', principal: next.username, accessExp: next.accessExp },
      'token refresh succeeded',
    );
    return next;
  } catch (err) {
    logger.info({ ev: 'auth:refresh-failed', err: (err as Error).message }, 'token refresh failed; de-authenticating');
    clearSessionCookie(res);
    return null;
  }
}

/** Best-effort host extraction for logging an authorize URL without its query. */
function safeHost(url: string): string | null {
  try {
    return new URL(url).host;
  } catch {
    return null;
  }
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
