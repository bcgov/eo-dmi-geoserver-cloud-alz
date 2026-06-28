/**
 * Keycloak OIDC relying-party logic (openid-client v6, functional API).
 *
 * Flow: Authorization Code + PKCE (S256). Discovery is performed once at boot
 * and cached. The login → callback round-trip is itself stateless: the PKCE
 * verifier, state and nonce are sealed into a short-lived transaction cookie
 * rather than a server-side store.
 */
import * as client from 'openid-client';
import type { Request, Response } from 'express';
import { config } from './config.ts';
import { logger } from './logger.ts';
import { seal, open } from './jwe.ts';

const TX_COOKIE = `${config.session.cookieName}_tx`;
const TX_TTL = '600s'; // login transactions are short-lived

let configuration: client.Configuration | undefined;

/** Discover the issuer metadata and build the client Configuration (once). */
export async function initOidc(): Promise<void> {
  configuration = await client.discovery(
    new URL(config.oidc.issuer),
    config.oidc.clientId,
    config.oidc.clientSecret,
  );
  logger.info({ issuer: config.oidc.issuer }, 'OIDC discovery complete');
}

function getConfig(): client.Configuration {
  if (!configuration) {
    throw new Error('OIDC not initialised — call initOidc() before serving requests.');
  }
  return configuration;
}

/**
 * Extract an optional, non-empty string claim. Used for presentation-only
 * claims (e.g. display_name) where absence is tolerated — unlike the identity
 * claim, a missing value must NOT fail the login.
 */
function optionalStringClaim(
  claims: client.IDToken | undefined,
  name: string,
): string | undefined {
  const value = claims?.[name];
  return typeof value === 'string' && value !== '' ? value : undefined;
}

interface LoginTx {
  state: string;
  nonce: string;
  codeVerifier: string;
  returnTo: string;
}

/**
 * Begin login: generate PKCE + state + nonce, persist them in a transaction
 * cookie, and return the Keycloak authorization URL to redirect the browser to.
 */
export async function beginLogin(
  res: Response,
  returnTo: string,
): Promise<string> {
  const codeVerifier = client.randomPKCECodeVerifier();
  const codeChallenge = await client.calculatePKCECodeChallenge(codeVerifier);
  const state = client.randomState();
  const nonce = client.randomNonce();

  const tx: LoginTx = { state, nonce, codeVerifier, returnTo };
  const txToken = await seal({ ...tx }, TX_TTL);
  res.append(
    'Set-Cookie',
    `${TX_COOKIE}=${txToken}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600`,
  );

  const url = client.buildAuthorizationUrl(getConfig(), {
    redirect_uri: config.oidc.redirectUri,
    scope: config.oidc.scopes,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    state,
    nonce,
  });
  return url.href;
}

export interface CallbackResult {
  sub: string;
  username: string;
  /** Human-readable display name (display_name claim), if present. */
  displayName?: string;
  accessExp: number;
  refreshToken: string;
  idToken?: string;
  returnTo: string;
}

/**
 * Complete login: validate the transaction cookie, exchange the code, and let
 * openid-client validate the ID token (signature via JWKS, iss, aud, exp,
 * nonce) and state. Returns the data needed to build a session.
 */
export async function completeLogin(req: Request): Promise<CallbackResult> {
  const txRaw = readTxCookie(req);
  if (!txRaw) throw new Error('missing login transaction cookie');

  const payload = await open(txRaw);
  const tx = payload as unknown as LoginTx;
  if (!tx.state || !tx.nonce || !tx.codeVerifier) {
    throw new Error('malformed login transaction');
  }

  // Reconstruct the absolute callback URL from configured origin (never from
  // client-supplied Host) plus the actual query string Keycloak appended.
  const currentUrl = new URL(config.oidc.redirectUri);
  currentUrl.search = new URL(req.originalUrl, config.publicOrigin).search;

  const tokens = await client.authorizationCodeGrant(getConfig(), currentUrl, {
    pkceCodeVerifier: tx.codeVerifier,
    expectedState: tx.state,
    expectedNonce: tx.nonce,
    idTokenExpected: true,
  });

  const claims = tokens.claims();
  if (!claims) throw new Error('token response had no ID token claims');

  const username = claims[config.usernameClaim];
  if (typeof username !== 'string' || username === '') {
    throw new Error(`ID token missing string claim "${config.usernameClaim}"`);
  }
  if (!tokens.refresh_token) {
    throw new Error('token response had no refresh_token');
  }

  return {
    sub: String(claims.sub),
    username,
    displayName: optionalStringClaim(claims, config.displayNameClaim),
    accessExp: accessExpiry(tokens, claims),
    refreshToken: tokens.refresh_token,
    idToken: tokens.id_token,
    returnTo: tx.returnTo || config.defaultReturnTo,
  };
}

export interface RefreshResult {
  username: string;
  /** Human-readable display name (display_name claim), if present. */
  displayName?: string;
  sub: string;
  accessExp: number;
  refreshToken: string;
  idToken?: string;
}

/** Silent renewal via the refresh token grant. Throws on failure (§6). */
export async function refresh(refreshToken: string): Promise<RefreshResult> {
  const tokens = await client.refreshTokenGrant(getConfig(), refreshToken);
  const claims = tokens.claims();

  const username =
    claims && typeof claims[config.usernameClaim] === 'string'
      ? (claims[config.usernameClaim] as string)
      : undefined;

  return {
    sub: claims ? String(claims.sub) : '',
    username: username ?? '',
    displayName: optionalStringClaim(claims, config.displayNameClaim),
    accessExp: accessExpiry(tokens, claims),
    // Keycloak rotates refresh tokens; fall back to the old one if not returned.
    refreshToken: tokens.refresh_token ?? refreshToken,
    idToken: tokens.id_token,
  };
}

/** Build the Keycloak end-session (RP-initiated logout) URL. */
export function buildLogoutUrl(idToken?: string): string {
  const params: Record<string, string> = {};
  if (config.oidc.postLogoutRedirectUri) {
    params.post_logout_redirect_uri = config.oidc.postLogoutRedirectUri;
  }
  if (idToken) params.id_token_hint = idToken;
  return client.buildEndSessionUrl(getConfig(), params).href;
}

/** Clear the transient login-transaction cookie. */
export function clearTxCookie(res: Response): void {
  res.append('Set-Cookie', `${TX_COOKIE}=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0`);
}

function readTxCookie(req: Request): string | undefined {
  const header = req.headers.cookie;
  if (!header) return undefined;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    if (part.slice(0, idx).trim() === TX_COOKIE) {
      return decodeURIComponent(part.slice(idx + 1).trim());
    }
  }
  return undefined;
}

/**
 * Determine the Unix-seconds expiry of the access token. Prefer the token
 * response's expires_in; fall back to the ID token exp claim.
 */
function accessExpiry(
  tokens: client.TokenEndpointResponse,
  claims: client.IDToken | undefined,
): number {
  const now = Math.floor(Date.now() / 1000);
  if (typeof tokens.expires_in === 'number') return now + tokens.expires_in;
  if (claims && typeof claims.exp === 'number') return claims.exp;
  return now + 60; // conservative default → forces an early refresh
}
