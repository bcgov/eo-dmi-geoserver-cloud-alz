/**
 * Centralised, validated configuration.
 *
 * All runtime knobs come from environment variables (injected by Terraform /
 * App Service). We validate them once at boot and fail fast with a clear error
 * rather than discovering a missing value deep inside a request handler.
 */

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optional(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

function bool(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value === undefined || value === "") return fallback;
  return value.toLowerCase() === "true";
}

function int(name: string, fallback: number): number {
  const value = process.env[name];
  if (value === undefined || value === "") return fallback;
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(
      `Environment variable ${name} must be an integer, got: ${value}`,
    );
  }
  return parsed;
}

/** Comma-separated env list → lower-cased, trimmed, de-blanked array. */
function csvLower(name: string): string[] {
  return optional(name, "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

/** Strip a single trailing slash so we can safely concatenate paths. */
function trimTrailingSlash(value: string): string {
  return value.endsWith("/") ? value.slice(0, -1) : value;
}

const sessionSecret = required("SESSION_COOKIE_SECRET");
if (Buffer.byteLength(sessionSecret, "utf8") < 32) {
  throw new Error("SESSION_COOKIE_SECRET must be at least 32 bytes.");
}

export const config = {
  port: int("PORT", 8080),
  logLevel: optional("LOG_LEVEL", "info"),

  oidc: {
    issuer: required("OIDC_ISSUER"),
    clientId: required("OIDC_CLIENT_ID"),
    clientSecret: required("OIDC_CLIENT_SECRET"),
    redirectUri: required("OIDC_REDIRECT_URI"),
    postLogoutRedirectUri: optional("OIDC_POST_LOGOUT_REDIRECT_URI", ""),
    scopes: optional("OIDC_SCOPES", "openid profile email"),
  },

  session: {
    secret: sessionSecret,
    cookieName: optional("SESSION_COOKIE_NAME", "gs_sso"),
    maxAgeSeconds: int("SESSION_MAX_AGE_SECONDS", 43_200), // 12h absolute cap
  },

  gateway: {
    origin: trimTrailingSlash(required("GATEWAY_ORIGIN")),
    tlsInsecure: bool("GATEWAY_TLS_INSECURE", false),
    connectTimeoutMs: int("GATEWAY_CONNECT_TIMEOUT_MS", 5_000),
    readTimeoutMs: int("GATEWAY_READ_TIMEOUT_MS", 60_000),
  },

  publicOrigin: trimTrailingSlash(required("PUBLIC_ORIGIN")),

  identityHeader: optional("GS_IDENTITY_HEADER", "sec-username").toLowerCase(),
  // Header name for the GeoServer role set; must start with "sec-" so the proxy
  // strips client-injected values before re-injecting the trusted value.
  rolesHeader: optional("GS_ROLES_HEADER", "sec-roles").toLowerCase(),
  // Comma-separated GeoServer roles injected for every OIDC-authenticated session.
  // All IDIR users accessing this system are authorised operators; ROLE_ADMINISTRATOR
  // is required for the GeoServer REST API. Fine-grained ACL is handled by geoserver-acl.
  oidcRoles: optional("OIDC_ROLES", "ROLE_ADMINISTRATOR"),
  // Principal injected as sec-username. Switched from the IDIR GUID to `email`
  // so GeoServer's UI shows an identifiable username; roles key on this value.
  usernameClaim: optional("USERNAME_CLAIM", "email"),
  // Lower-case the principal so the same user can't register twice (email vs UPN casing).
  usernameLowercase: bool("USERNAME_LOWERCASE", false),
  // Stable IDIR GUID claim — stored alongside the email for audit/reference (not the principal).
  userGuidClaim: optional("USER_GUID_CLAIM", "idir_user_guid"),

  // Display name: a human-readable label injected alongside the identity header.
  displayNameHeader: optional(
    "DISPLAY_NAME_HEADER",
    "sec-user-display-name",
  ).toLowerCase(),
  displayNameClaim: optional("DISPLAY_NAME_CLAIM", "display_name"),

  machineAuthPassthrough: bool("MACHINE_AUTH_PASSTHROUGH", false),

  /** Convenience redirect target when a browser hits "/". */
  defaultReturnTo: optional("DEFAULT_RETURN_TO", "/geoserver/cloud/web/"),

  /**
   * pgconfig DB connection for auto-registering users in gssec.user_display_names
   * on login + serving the /admin/idir-users reference view. All fields default
   * to '' so the app starts cleanly when the DB env vars are absent.
   */
  db: {
    host: optional("PGCONFIG_HOST", ""),
    port: int("PGCONFIG_PORT", 5432),
    database: optional("PGCONFIG_DATABASE", ""),
    username: optional("PGCONFIG_USERNAME", ""),
    password: optional("PGCONFIG_PASSWORD", ""),
  },

  /**
   * GeoServer admin REST access — registers each IDIR user (by principal/email)
   * in the default user/group service so they show under Security → Users/Groups.
   * Disabled unless GEOSERVER_ADMIN_PASSWORD is set. Reuses gateway.origin.
   */
  geoserver: {
    adminUser: optional("GEOSERVER_ADMIN_USERNAME", "admin"),
    adminPassword: optional("GEOSERVER_ADMIN_PASSWORD", ""),
    basePath: trimTrailingSlash(
      optional("GEOSERVER_BASE_PATH", "/geoserver/cloud"),
    ),
    serviceName: optional("GEOSERVER_USERGROUP_SERVICE", "default"),
    timeoutMs: int("GEOSERVER_REST_TIMEOUT_MS", 5_000),
  },

  /**
   * Principals (lower-cased emails) allowed to view the /admin/idir-users
   * reference page (display name ↔ email ↔ GUID). Empty → the page is disabled.
   */
  adminPrincipals: csvLower("GEOSERVER_ADMIN_PRINCIPALS"),

  /**
   * Debug instrumentation (see debug.ts). Verbose by default for this testing
   * round so the failure point is visible without a redeploy.
   *
   *  - headers (DEBUG_HEADERS, default true): log the full sanitised request and
   *    response headers at every hop (browser↔proxy and proxy↔gateway), with a
   *    per-request reqId for end-to-end correlation. Secret values are masked.
   *
   *  - unsafe (DEBUG_UNSAFE_HEADERS, default FALSE): also reveal RAW values —
   *    cookie bytes, Basic creds, etc. — AND disable the pino redaction backstop
   *    (logger.ts). Use ONLY for a controlled, private test run. Turn it off
   *    afterwards: it can write the encrypted session cookie + tokens to stdout.
   */
  debug: {
    headers: bool("DEBUG_HEADERS", true),
    unsafe: bool("DEBUG_UNSAFE_HEADERS", false),
  },
} as const;

export type AppConfig = typeof config;
