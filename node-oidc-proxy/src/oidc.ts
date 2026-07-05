/**
 * Keycloak OIDC relying-party logic (openid-client v6, functional API).
 *
 * Flow: Authorization Code + PKCE (S256). Discovery is performed once at boot
 * and cached. The login → callback round-trip is itself stateless: the PKCE
 * verifier, state and nonce are sealed into a short-lived transaction cookie
 * rather than a server-side store.
 *
 * DEBUG: this module logs the discovered endpoints at boot, the authorize
 * request, and — most importantly — the ID-token claim set at callback. If the
 * principal claim (config.usernameClaim, e.g. `email`) is absent, that single
 * `oidc:principal-claim-missing` line names the exact problem.
 */
import * as client from 'openid-client';
import type { Request, Response } from 'express';
import { config } from './config.ts';
import { logger } from './logger.ts';
import { seal, open } from './jwe.ts';
import { getReqId } from './debug.ts';

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
  // Log the resolved endpoints — confirms the issuer is reachable and that the
  // authorize / token / end-session / jwks URLs are what we expect.
  try {
    const md = (
      configuration as unknown as { serverMetadata?: () => Record<string, unknown> }
    ).serverMetadata?.();
    logger.info(
      {
        ev: 'oidc:discovery',
        issuer: config.oidc.issuer,
        authorization_endpoint: md?.authorization_endpoint ?? null,
        token_endpoint: md?.token_endpoint ?? null,
        end_session_endpoint: md?.end_session_endpoint ?? null,
        jwks_uri: md?.jwks_uri ?? null,
      },
      'OIDC discovery complete',
    );
  } catch {
    logger.info({ ev: 'oidc:discovery', issuer: config.oidc.issuer }, 'OIDC discovery complete');
  }
}

function getConfig(): client.Configuration {
  if (!configuration) {
    throw new Error('OIDC not initialised — call initOidc() before serving requests.');
  }
  return configuration;
}

/**
 * Extract an optional, non-empty string claim. Used for presentation-only
 * claims (display_name, idir_user_guid) where absence is tolerated — unlike the
 * identity claim, a missing value must NOT fail the login.
 */
function optionalStringClaim(
  claims: client.IDToken | undefined,
  name: string,
): string | undefined {
  const value = claims?.[name];
  return typeof value === 'string' && value !== '' ? value : undefined;
}

/**
 * Read the principal (sec-username) claim. This is the GeoServer identity that
 * roles are keyed on. Optionally lower-cased so a user can't end up registered
 * twice under different casing (email vs. UPN).
 */
function principalFromClaims(claims: client.IDToken): string {
  const raw = claims[config.usernameClaim];
  if (typeof raw !== 'string' || raw === '') {
    // Name exactly which claim is missing and what DID arrive — the fastest way
    // to spot a missing protocol mapper (e.g. `email` not on the ID token).
    logger.error(
      {
        ev: 'oidc:principal-claim-missing',
        usernameClaim: config.usernameClaim,
        claimNames: Object.keys(claims),
      },
      `ID token is missing the principal claim "${config.usernameClaim}"`,
    );
    throw new Error(`ID token missing string claim "${config.usernameClaim}"`);
  }
  return config.usernameLowercase ? raw.toLowerCase() : raw;
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

  logger.debug(
    {
      ev: 'oidc:authorize-url',
      redirect_uri: config.oidc.redirectUri,
      scope: config.oidc.scopes,
      code_challenge_method: 'S256',
      txCookieBytes: txToken.length,
    },
    'built Keycloak authorization URL',
  );
  return url.href;
}

export interface CallbackResult {
  sub: string;
  /** Principal injected as sec-username (e.g. lower-cased email). */
  username: string;
  /** Stable IDIR GUID (idir_user_guid claim) — kept for audit/reference. */
  guid?: string;
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
  const reqId = getReqId(req);
  const txRaw = readTxCookie(req);
  if (!txRaw) {
    logger.error({ reqId, ev: 'oidc:tx-cookie-missing' }, 'login transaction cookie absent at callback');
    throw new Error('missing login transaction cookie');
  }

  const payload = await open(txRaw);
  const tx = payload as unknown as LoginTx;
  if (!tx.state || !tx.nonce || !tx.codeVerifier) {
    throw new Error('malformed login transaction');
  }

  // Reconstruct the absolute callback URL from configured origin (never from
  // client-supplied Host) plus the actual query string Keycloak appended.
  const currentUrl = new URL(config.oidc.redirectUri);
  currentUrl.search = new URL(req.originalUrl, config.publicOrigin).search;

  logger.debug(
    { reqId, ev: 'oidc:code-exchange', callbackUrl: `${currentUrl.origin}${currentUrl.pathname}` },
    'exchanging authorization code for tokens',
  );

  const tokens = await client.authorizationCodeGrant(getConfig(), currentUrl, {
    pkceCodeVerifier: tx.codeVerifier,
    expectedState: tx.state,
    expectedNonce: tx.nonce,
    idTokenExpected: true,
  });

  const claims = tokens.claims();
  if (!claims) throw new Error('token response had no ID token claims');

  // GOLD LINE: the full claim-name set + whether each claim we depend on is
  // present. If `usernameClaim` (email) isn't here, principalFromClaims throws
  // next and the callback fails — this tells you why before that happens.
  logger.info(
    {
      reqId,
      ev: 'oidc:callback-claims',
      claimNames: Object.keys(claims),
      usernameClaim: config.usernameClaim,
      hasUsernameClaim: typeof claims[config.usernameClaim] === 'string',
      hasGuidClaim: !!optionalStringClaim(claims, config.userGuidClaim),
      hasDisplayNameClaim: !!optionalStringClaim(claims, config.displayNameClaim),
      sub: String(claims.sub),
      iss: claims.iss ?? null,
      aud: claims.aud ?? null,
      exp: claims.exp ?? null,
      hasRefreshToken: !!tokens.refresh_token,
      hasIdToken: !!tokens.id_token,
    },
    'oidc:callback-claims — ID token validated',
  );

  const username = principalFromClaims(claims);
  if (!tokens.refresh_token) {
    throw new Error('token response had no refresh_token');
  }

  return {
    sub: String(claims.sub),
    username,
    guid: optionalStringClaim(claims, config.userGuidClaim),
    displayName: optionalStringClaim(claims, config.displayNameClaim),
    accessExp: accessExpiry(tokens, claims),
    refreshToken: tokens.refresh_token,
    idToken: tokens.id_token,
    returnTo: tx.returnTo || config.defaultReturnTo,
  };
}

export interface RefreshResult {
  username: string;
  guid?: string;
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
      ? (config.usernameLowercase
          ? (claims[config.usernameClaim] as string).toLowerCase()
          : (claims[config.usernameClaim] as string))
      : undefined;

  logger.debug(
    {
      ev: 'oidc:refresh',
      hasUsernameClaim: !!username,
      rotatedRefreshToken: !!tokens.refresh_token,
      accessExp: accessExpiry(tokens, claims),
    },
    'refresh token grant complete',
  );

  return {
    sub: claims ? String(claims.sub) : '',
    username: username ?? '',
    guid: optionalStringClaim(claims, config.userGuidClaim),
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
