/**
 * Stateless session: a JWE carried in an HttpOnly cookie. There is NO
 * server-side session store — everything needed to authorise a request and to
 * silently refresh tokens lives (encrypted) in the cookie (contract §6).
 *
 * Keep the payload small — browsers cap cookies at ~4KB.
 */
import * as cookie from 'cookie';
import type { Request, Response } from 'express';
import { config } from './config.ts';
import { logger } from './logger.ts';
import { seal, open } from './jwe.ts';

/** The decrypted session payload. */
export interface SessionData {
  /** OIDC subject identifier. */
  sub: string;
  /** Value injected as the trusted identity header (the IDIR GUID). */
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

/** Encrypt a session payload into a compact JWE string. */
export function sealSession(data: SessionData): Promise<string> {
  return seal(
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
    logger.debug({ err: (err as Error).message }, 'session cookie rejected');
    return null;
  }
}

/** Read and decrypt the session cookie from an inbound request. */
export async function readSession(req: Request): Promise<SessionData | null> {
  const header = req.headers.cookie;
  if (!header) return null;
  const token = cookie.parse(header)[config.session.cookieName];
  if (!token) return null;
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
}

/** Clear the session cookie (logout / refresh failure). */
export function clearSessionCookie(res: Response): void {
  res.append('Set-Cookie', cookie.serialize(config.session.cookieName, '', cookieOptions(0)));
}
