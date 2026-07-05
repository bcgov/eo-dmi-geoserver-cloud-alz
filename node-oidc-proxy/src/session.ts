/**
 * Stateless session: a JWE carried in an HttpOnly cookie. There is NO
 * server-side session store — everything needed to authorise a request and to
 * silently refresh tokens lives (encrypted) in the cookie (contract §6).
 *
 * Keep the payload small — browsers cap cookies at ~4KB.
 *
 * DEBUG: seal logs the sealed-cookie byte size and warns if it approaches the
 * ~4KB browser cap (a too-large cookie is silently dropped by the browser →
 * looks exactly like "login didn't stick"). open/read log why a cookie was
 * rejected.
 */
import * as cookie from 'cookie';
import type { Request, Response } from 'express';
import { config } from './config.ts';
import { logger } from './logger.ts';
import { seal, open } from './jwe.ts';

/** Browsers commonly drop a single cookie larger than ~4096 bytes. */
const COOKIE_SIZE_WARN = 3800;

/** The decrypted session payload. */
export interface SessionData {
  /** OIDC subject identifier. */
  sub: string;
  /** Value injected as the trusted identity header (the principal / email). */
  username: string;
  /** Human-readable display name injected as the display-name header (for UI). */
  displayName?: string;
  /** Unix seconds at which the underlying access token expires. */
  accessExp: number;
  /** Refresh token used for silent renewal. */
  refreshToken: string;
  /** ID token, retained only for logout id_token_hint. */
  idToken?: string;
}

/** Encrypt a session payload into a compact JWE. */
export async function sealSession(data: SessionData): Promise<string> {
  const token = await seal(
    {
      sub: data.sub,
      username: data.username,
      accessExp: data.accessExp,
      refreshToken: data.refreshToken,
      ...(data.displayName ? { displayName: data.displayName } : {}),
      ...(data.idToken ? { idToken: data.idToken } : {}),
    },
    // Absolute session cap; rolling expiry is re-applied on every re-issue.
    `${config.session.maxAgeSeconds}s`,
  );

  const bytes = Buffer.byteLength(token, 'utf8');
  const fields = {
    sub: true,
    username: true,
    accessExp: true,
    refreshToken: true,
    displayName: !!data.displayName,
    idToken: !!data.idToken,
  };
  if (bytes >= COOKIE_SIZE_WARN) {
    logger.warn(
      { ev: 'session:seal-large', cookieBytes: bytes, principal: data.username, fields },
      `session cookie is ${bytes}B — approaching the ~4KB browser cap; the browser may drop it (login would appear not to stick)`,
    );
  } else {
    logger.debug(
      { ev: 'session:seal', cookieBytes: bytes, principal: data.username, fields },
      'sealed session cookie',
    );
  }
  return token;
}

/** Decrypt and validate a session cookie. Returns null on any failure. */
export async function openSession(token: string): Promise<SessionData | null> {
  try {
    const payload = await open(token);
    if (
      typeof payload.sub !== 'string' ||
      typeof payload.username !== 'string' ||
      typeof payload.accessExp !== 'number' ||
      typeof payload.refreshToken !== 'string'
    ) {
      logger.warn(
        {
          ev: 'session:open-malformed',
          hasSub: typeof payload.sub,
          hasUsername: typeof payload.username,
          hasAccessExp: typeof payload.accessExp,
          hasRefreshToken: typeof payload.refreshToken,
        },
        'session cookie decrypted but failed shape validation',
      );
      return null;
    }
    return {
      sub: payload.sub,
      username: payload.username,
      displayName: typeof payload.displayName === 'string' ? payload.displayName : undefined,
      accessExp: payload.accessExp,
      refreshToken: payload.refreshToken,
      idToken: typeof payload.idToken === 'string' ? payload.idToken : undefined,
    };
  } catch (err) {
    // Tampered / expired / wrong-key cookies are simply treated as "no session".
    logger.debug({ ev: 'session:open-rejected', err: (err as Error).message }, 'session cookie rejected');
    return null;
  }
}

/** Read and decrypt the session cookie from an inbound request. */
export async function readSession(req: Request): Promise<SessionData | null> {
  const header = req.headers.cookie;
  if (!header) return null;
  const token = cookie.parse(header)[config.session.cookieName];
  if (!token) {
    logger.debug(
      { ev: 'session:no-cookie', cookieName: config.session.cookieName, cookiesPresent: !!header },
      'no session cookie on request',
    );
    return null;
  }
  return openSession(token);
}

function cookieOptions(maxAge: number): cookie.SerializeOptions {
  return {
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge,
  };
}

/** Write the session cookie onto a response (HttpOnly; Secure; SameSite=Lax). */
export function writeSessionCookie(res: Response, token: string): void {
  res.append(
    'Set-Cookie',
    cookie.serialize(config.session.cookieName, token, cookieOptions(config.session.maxAgeSeconds)),
  );
  logger.debug(
    { ev: 'session:write-cookie', cookieName: config.session.cookieName, maxAgeSeconds: config.session.maxAgeSeconds },
    'wrote session cookie',
  );
}

/** Clear the session cookie (logout / refresh failure). */
export function clearSessionCookie(res: Response): void {
  res.append('Set-Cookie', cookie.serialize(config.session.cookieName, '', cookieOptions(0)));
  logger.debug({ ev: 'session:clear-cookie', cookieName: config.session.cookieName }, 'cleared session cookie');
}
