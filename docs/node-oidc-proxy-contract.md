# Node OIDC Edge Proxy — Container Contract

A small puole service in Postgres, and enforces ACL.

It must be a **drop-in** that can later be replaced by Azure Front Door Premium without
changing GeoServer — so it relies only on standard reverse-proxy + `X-Forwarded-*` semantics.

---

## 1. Responsibilities

1. Terminate browser traffic, run Keycloak OIDC (Authorization Code + **PKCE**).
2. Establish a stateless, encrypted **session cookie** (no server-side store).
3. On every proxied request: **strip** any clieblic-facing reverse proxy that sits **in front of the internal GeoServer Cloud
gateway** (Azure Container Apps, internal load balancer). It performs the Keycloak OIDC
Authorization-Code-flow login, holds a **stateless signed/encrypted cookie session**, and on
every request injects a trusted identity header (`sec-username`) into the upstream request
before reverse-proxying to the gateway. GeoServer trusts that header (pre-auth filter),
resolves roles from its JDBC role service keyed on the injected identity, then **inject**
   `sec-username: <idir_user_guid>` from the validated session.
4. Reverse-proxy everything else to the internal gateway, **preserving path, query, method,
   body (streamed), and GeoServer cookies** (e.g. `JSESSIONID`).
5. Set `X-Forwarded-*` so GeoServer generates correct absolute URLs.
6. Silent **token refresh** using the refresh token.
7. Pass through **machine-client** auth (HTTP Basic / `authkey` query param) untouched — those
   are handled by GeoServer directly (local users / auth-key extension), not OIDC.

## 2. Routes the app MUST expose

| Method | Path | Auth | Behavior |
|---|---|---|---|
| GET | `/healthz` | none | `200 {"status":"ok"}`. No proxy, no auth. Used by App Service health check + Docker HEALTHCHECK. |
| GET | `/auth/login` | none | Build state+nonce+PKCE, 302 to Keycloak `authorization_endpoint`. |
| GET | `/auth/callback` | none | **The registered redirect URI.** Validate `state`, exchange `code` at `token_endpoint`, validate ID token (sig via JWKS, `iss`, `aud`, `exp`, `nonce`), set session cookie, 302 to original `returnTo` (default `/geoserver/cloud/web/`). |
| GET | `/auth/logout` | none | Clear session cookie, 302 to Keycloak `end_session_endpoint` with `post_logout_redirect_uri` + `id_token_hint`. |
| ALL | `/*` | session | If valid session → inject header + proxy. Else apply the **unauthenticated decision matrix** (§5). |

> Keep the GeoServer base path **identical end-to-end** (`/geoserver/cloud`). Do **not** rewrite
> paths. Optionally 302 `/` → `/geoserver/cloud/web/` for convenience.

## 3. OIDC details (BC Gov Keycloak "standard" realm)

- Issuer: `https://test.loginproxy.gov.bc.ca/auth/realms/standard`
- Discovery: `<issuer>/.well-known/openid-configuration` (prefer auto-discovery via `openid-client`)
- authorization_endpoint: `<issuer>/protocol/openid-connect/auth`
- token_endpoint: `<issuer>/protocol/openid-connect/token`
- jwks_uri: `<issuer>/protocol/openid-connect/certs`
- end_session_endpoint: `<issuer>/protocol/openid-connect/logout`
- Flow: `response_type=code`, **PKCE (S256)**, `scope="openid profile email"`
- **Identity claim → `sec-username` = `idir_user_guid`** (BC Gov IDIR; stable GUID per user across account renames).
- Recommended library: [`openid-client`](https://github.com/panva/node-openid-client) (v6) + `express`.

## 4. Header contract with GeoServer (critical)

**Inject (only when a valid session exists):**
```
sec-username: <idir_user_guid>
sec-user-display-name: <display_name>
```
(The display name is extracted from the Keycloak token's `display_name` claim and used by GeoServer's UI to show a human-readable name instead of the GUID.)

**Always strip from the inbound client request before forwarding (anti-spoofing), regardless of auth state:**
```
sec-username, sec-user-display-name, sec-roles, sec-*, x-gsc-username, x-gsc-roles, x-gsc-*
```
(Overwrite, never pass through client-supplied values.)

**Set forwarded headers** (use the configured `PUBLIC_ORIGIN`, not client-supplied Host):
```
X-Forwarded-Host:  <public host>
X-Forwarded-Proto: https
X-Forwarded-Port:  443
X-Forwarded-For:   <client ip>   # append, don't overwrite the chain
```
**Pass through transparently** (both directions): `Cookie` / `Set-Cookie` (so `JSESSIONID` and
GeoServer's Wicket session survive). The proxy's own session cookie uses a distinct name.

> Roles are **not** sent as a header in this design — GeoServer resolves them from its JDBC role
> service keyed on the username. (`sec-roles` is reserved for a future header-based role source.)

## 5. Unauthenticated request decision matrix

Evaluate in order:
1. Path is `/healthz` or `/auth/*` → handle locally (no proxy).
2. Request has `Authorization: Basic …` **or** a `authkey=` query param → **pass through to the
   gateway WITHOUT injecting `sec-username`** (GeoServer handles Basic/auth-key). Still strip
   spoofed `sec-*`.
3. Browser request (`Accept` contains `text/html`) → `302 /auth/login?returnTo=<original-url>`.
4. Otherwise (API/XHR) → `401` with `WWW-Authenticate: Bearer` (no redirect).

> **Auth-key scope, and does it support writes?** GeoServer's authkey module is wired (by
> `infra/scripts/configure-geoserver-security.sh`, step 6) into the `default` (OWS: WMS/WFS/WCS/WPS)
> and `gwc` filter chains only — never `web` or `rest`. This matches GeoServer's own documented
> limitation: authkey "is meant to be used with OGC services... it won't work properly against the
> administration GUI, nor RESTConfig." Practically: an `?authkey=<key>` request **can** perform a
> WFS-T write (or any OWS write operation) exactly as far as **geoserver-acl** — a separate, DB-backed
> authorization microservice, not GeoServer's own role system — permits for that specific resolved
> username. Authentication and authorization are deliberately split across two systems here:
>
> - **Authentication** (who is this?): `var.machine_client_usernames` (Terraform) + this script
>   provision one authkey identity per machine/API client. This is identity only — it grants no
>   access by itself, and this script never associates roles with these users.
> - **Authorization** (what can they do?): `geo-server-app-config/catalog/acl_rules.yaml` defines a
>   `username`-scoped rule per machine client (e.g. `username: svc-machine-wildlife`, `workspace:
>   wildlife`, `access: WRITE`), reconciled into geoserver-acl via `geoserver-apply run <env>`. Scoping
>   by `username` — instead of a shared `role` every other machine client might also hold — means one
>   client's grant is confined to exactly the workspace/dataset its rule names; a second machine
>   client with its own `username` rule can be scoped to a different workspace entirely.
>
> It **cannot** authenticate against `/rest/...` (catalog/config management) or `/web/...` (admin GUI)
> — those endpoints ignore the authkey param and fall through to anonymous/401, regardless of what
> geoserver-acl would have permitted. A caller needing REST-config writes must use Basic auth against
> a real user or an OIDC session.

## 6. Session cookie (stateless)

- Name: `${SESSION_COOKIE_NAME}` (default `gs_sso`), distinct from `JSESSIONID`.
- Encrypted (JWE, dir + A256GCM) or signed-then-encrypted, key from `SESSION_COOKIE_SECRET` (≥32 bytes).
- Flags: `HttpOnly; Secure; SameSite=Lax; Path=/`.
- Payload (keep small — cookies cap ~4KB): `sub`, `idir_user_guid`, `exp`, `refresh_token`
  (and `id_token` only if needed for logout `id_token_hint`). **Do not** store the full access
  token unless required; never log tokens.
- Refresh: when access/session near expiry, use `refresh_token` at `token_endpoint`, re-issue cookie.
  On refresh failure → treat as unauthenticated (§5).
- Rolling expiry recommended; absolute max-age e.g. 12h.

## 7. Reverse-proxy requirements

- Target base: `${GATEWAY_ORIGIN}` (scheme+host, **no path**). Preserve the full incoming path+query.
- **Stream** request and response bodies (large WMS rasters / GetCapabilities) — do not buffer.
- Preserve method and headers except hop-by-hop (`Connection`, `Keep-Alive`, `Transfer-Encoding`,
  `Upgrade`, `Proxy-*`, `TE`, `Trailer`) and the stripped `sec-*`/`x-gsc-*`.
- TLS to gateway: ACA presents a valid public cert for the env domain → verify normally
  (`rejectUnauthorized: true`). Expose `GATEWAY_TLS_INSECURE=false` knob just in case.
- Timeouts: connect 5s, read 60s (match the gateway). Return `502` on upstream failure.
- WebSockets: not required (the 3.0 WebMVC gateway dropped WS routing).
- `app.set('trust proxy', true)` — App Service / Front Door sits in front.

## 8. Environment variables (injected by Terraform / App Service)

| Var | Example | Notes |
|---|---|---|
| `PORT` | `8080` | Listen on `0.0.0.0:$PORT`. App Service sets this. |
| `OIDC_ISSUER` | `https://test.loginproxy.gov.bc.ca/auth/realms/standard` | |
| `OIDC_CLIENT_ID` | `eo-dmi-geoserver-cloud-alz-6502` | |
| `OIDC_CLIENT_SECRET` | *(secret)* | From Key Vault → App Service setting. |
| `OIDC_REDIRECT_URI` | `https://<public-host>/auth/callback` | Must be **registered in Keycloak**. |
| `OIDC_POST_LOGOUT_REDIRECT_URI` | `https://<public-host>/` | Register in Keycloak too. |
| `OIDC_SCOPES` | `openid profile email` | |
| `SESSION_COOKIE_SECRET` | *(secret, ≥32 bytes)* | From Key Vault. |
| `SESSION_COOKIE_NAME` | `gs_sso` | |
| `SESSION_MAX_AGE_SECONDS` | `43200` | Absolute cap. |
| `GATEWAY_ORIGIN` | `https://gateway.internal.<env-domain>` | Internal ACA gateway base (no path). Injected by TF. |
| `PUBLIC_ORIGIN` | `https://<public-host>` | For `X-Forwarded-Host` + redirect building. |
| `IDENTITY_HEADER` | `sec-username` | Header name injected to GeoServer (carries the GUID). |
| `USERNAME_CLAIM` | `idir_user_guid` | Keycloak claim extracted → injected as `sec-username` header value. |
| `DISPLAY_NAME_HEADER` | `sec-user-display-name` | Header name for the user's display name (for UI). |
| `DISPLAY_NAME_CLAIM` | `display_name` | Keycloak claim extracted → injected as display-name header value. |
| `MACHINE_AUTH_PASSTHROUGH` | `true` | Enables §5 rule 2. |
| `GATEWAY_TLS_INSECURE` | `false` | |
| `LOG_LEVEL` | `info` | Never log tokens/secrets. |

## 9. Dockerfile contract

- Multi-stage: builder (`npm ci --omit=dev` after build) → slim runtime (`node:22-alpine` or
  distroless `nodejs`).
- Run as **non-root** user.
- `EXPOSE 8080`; app listens on `0.0.0.0:$PORT`.
- `HEALTHCHECK` → `GET /healthz`.
- No secrets baked into the image. `.dockerignore` excludes `node_modules`, `.env`, tests.
- Publish to **GHCR**: `ghcr.io/<org>/<repo>:<tag>` (and `:sha-<short>`); multi-arch `linux/amd64`
  (App Service Linux). Sign if your supply-chain policy requires.

### Reference Dockerfile skeleton
```dockerfile
# build
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build            # if TS; omit for plain JS

# runtime
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && addgroup -S app && adduser -S app -G app
COPY --from=build /app/dist ./dist
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["node", "dist/server.js"]
```

## 10. Security requirements (must-haves)

- PKCE (S256); validate `state` and `nonce`; validate ID token signature + `iss`/`aud`/`exp`.
- `HttpOnly; Secure; SameSite=Lax` cookies; strong random `SESSION_COOKIE_SECRET`.
- **Always** strip inbound `sec-*` / `x-gsc-*`.
- Build redirect URIs from configured env (`OIDC_REDIRECT_URI`), never from client `Host`/`X-Forwarded-Host`.
- No tokens/secrets in logs.

## 11. What I (Terraform side) will provide / wire

- The internal gateway value for `GATEWAY_ORIGIN` (`.internal` FQDN), once backends are internal-only.
- `OIDC_CLIENT_SECRET` + `SESSION_COOKIE_SECRET` from Key Vault into the App Service settings.
- App Service (GHCR pull, VNet integration to reach the internal gateway), and locking the gateway
  so only the App Service can reach it.
- GeoServer: request-header pre-auth filter reading `sec-username` (fall-through to local admin),
  JDBC role service (Postgres), `auth-key` extension, ACL.
- GeoServer `authkey` filter (`default`+`gwc` chains only) plus one machine-client user and key
  per entry in `var.machine_client_usernames`, provisioned end-to-end by
  `configure-geoserver-security.sh` step 6 and `null_resource.secret_geoserver_machine_authkey`
  (`for_each` over usernames) — authentication only, see §5 above for the OGC-only / no-REST-write
  scope. Authorization for each username is a separate concern, owned entirely by
  `geo-server-app-config/catalog/acl_rules.yaml` (username-scoped ACL rules), not by Terraform.

## 12. What you must register in Keycloak (client `eo-dmi-geoserver-cloud-alz-6502`)

- Valid redirect URI: `https://<public-host>/auth/callback`
- Valid post-logout redirect URI: `https://<public-host>/`
- Web origins: `https://<public-host>` (or `+`)
- Confirm `idir_user_guid` and `display_name` are in the ID token.
