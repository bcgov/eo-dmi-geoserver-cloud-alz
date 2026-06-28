/**
 * Centralised, validated configuration.
 *
 * All runtime knobs come from environment variables (injected by Terraform /
 * App Service). We validate them once at boot and fail fast with a clear error
 * rather than discovering a missing value deep inside a request handler.
 */

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === '') {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optional(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value === '' ? fallback : value;
}

function bool(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value === undefined || value === '') return fallback;
  return value.toLowerCase() === 'true';
}

function int(name: string, fallback: number): number {
  const value = process.env[name];
  if (value === undefined || value === '') return fallback;
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Environment variable ${name} must be an integer, got: ${value}`);
  }
  return parsed;
}

/** Strip a single trailing slash so we can safely concatenate paths. */
function trimTrailingSlash(value: string): string {
  return value.endsWith('/') ? value.slice(0, -1) : value;
}

const sessionSecret = required('SESSION_COOKIE_SECRET');
if (Buffer.byteLength(sessionSecret, 'utf8') < 32) {
  throw new Error('SESSION_COOKIE_SECRET must be at least 32 bytes.');
}

export const config = {
  port: int('PORT', 8080),
  logLevel: optional('LOG_LEVEL', 'info'),

  oidc: {
    issuer: required('OIDC_ISSUER'),
    clientId: required('OIDC_CLIENT_ID'),
    clientSecret: required('OIDC_CLIENT_SECRET'),
    redirectUri: required('OIDC_REDIRECT_URI'),
    postLogoutRedirectUri: optional('OIDC_POST_LOGOUT_REDIRECT_URI', ''),
    scopes: optional('OIDC_SCOPES', 'openid profile email'),
  },

  session: {
    secret: sessionSecret,
    cookieName: optional('SESSION_COOKIE_NAME', 'gs_sso'),
    maxAgeSeconds: int('SESSION_MAX_AGE_SECONDS', 43_200), // 12h absolute cap
  },

  gateway: {
    origin: trimTrailingSlash(required('GATEWAY_ORIGIN')),
    tlsInsecure: bool('GATEWAY_TLS_INSECURE', false),
    connectTimeoutMs: int('GATEWAY_CONNECT_TIMEOUT_MS', 5_000),
    readTimeoutMs: int('GATEWAY_READ_TIMEOUT_MS', 60_000),
  },

  publicOrigin: trimTrailingSlash(required('PUBLIC_ORIGIN')),

  identityHeader: optional('IDENTITY_HEADER', 'sec-username').toLowerCase(),
  usernameClaim: optional('USERNAME_CLAIM', 'preferred_username'),

  // Display name: a human-readable label injected alongside the identity header
  // so GeoServer's UI can show e.g. "Mishra, Om WLRS:EX" instead of the raw GUID.
  // Role lookups still key on identityHeader (the GUID); this is presentation-only.
  displayNameHeader: optional('DISPLAY_NAME_HEADER', 'sec-user-display-name').toLowerCase(),
  displayNameClaim: optional('DISPLAY_NAME_CLAIM', 'display_name'),

  machineAuthPassthrough: bool('MACHINE_AUTH_PASSTHROUGH', true),

  /** Convenience redirect target when a browser hits "/". */
  defaultReturnTo: optional('DEFAULT_RETURN_TO', '/geoserver/cloud/web/'),
} as const;

export type AppConfig = typeof config;
