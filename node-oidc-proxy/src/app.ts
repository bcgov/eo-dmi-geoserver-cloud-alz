/**
 * Express wiring: health, the three /auth/* endpoints, an optional "/" courtesy
 * redirect, and the catch-all that applies the session / unauthenticated
 * decision matrix (contract §2, §5) before reverse-proxying.
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

export function createApp(): express.Express {
  const app = express();

  // App Service / Front Door terminates TLS in front of us.
  app.set('trust proxy', true);
  app.disable('x-powered-by');

  // --- Health check (no proxy, no auth) -----------------------------------
  app.get('/healthz', (_req, res) => {
    res.status(200).json({ status: 'ok' });
  });

  // --- OIDC: begin login --------------------------------------------------
  app.get('/auth/login', async (req, res) => {
    try {
      const returnTo = safePath(
        typeof req.query.returnTo === 'string' ? req.query.returnTo : undefined,
        config.defaultReturnTo,
      );
      const url = await beginLogin(res, returnTo);
      res.redirect(302, url);
    } catch (err) {
      logger.error({ err: (err as Error).message }, 'login initiation failed');
      res.status(500).json({ error: 'login_failed' });
    }
  });

  // --- OIDC: callback (the registered redirect URI) -----------------------
  app.get('/auth/callback', async (req, res) => {
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
      writeSessionCookie(res, await sealSession(session));
      clearTxCookie(res);
      res.redirect(302, safePath(result.returnTo, config.defaultReturnTo));
    } catch (err) {
      logger.error({ err: (err as Error).message }, 'callback failed');
      clearTxCookie(res);
      res.status(400).json({ error: 'invalid_callback' });
    }
  });

  // --- OIDC: logout -------------------------------------------------------
  app.get('/auth/logout', async (req, res) => {
    const session = await readSession(req);
    clearSessionCookie(res);
    clearTxCookie(res);
    res.redirect(302, buildLogoutUrl(session?.idToken));
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
  let session = await readSession(req);

  // Silent refresh when the access token is at/near expiry (contract §6).
  if (session && session.accessExp - REFRESH_SKEW_SECONDS <= nowSeconds()) {
    session = await tryRefresh(session, res);
  }

  if (session) {
    proxy(req, res, session.username, session.displayName);
    return;
  }

  // ---- Unauthenticated decision matrix (§5) ----
  // Rule 2: machine clients (Basic / authkey) pass through WITHOUT injection.
  if (config.machineAuthPassthrough && hasMachineAuth(req)) {
    proxy(req, res, undefined);
    return;
  }
  // Rule 3: browsers get redirected into the OIDC login.
  if (wantsHtml(req)) {
    const returnTo = encodeURIComponent(req.originalUrl);
    res.redirect(302, `/auth/login?returnTo=${returnTo}`);
    return;
  }
  // Rule 4: API/XHR clients get a 401 (no redirect).
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
    return next;
  } catch (err) {
    logger.info({ err: (err as Error).message }, 'token refresh failed; de-authenticating');
    clearSessionCookie(res);
    return null;
  }
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
