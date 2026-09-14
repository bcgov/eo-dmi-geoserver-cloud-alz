# Node OIDC Edge Proxy - Container Contract

The Node OIDC edge proxy is the public authentication entry point for the
GeoServer Cloud deployment. It runs on Azure App Service, reaches the internal
Container Apps gateway through VNet integration, and forwards requests without
changing the `/geoserver/cloud` path.

The proxy owns the browser OIDC flow and the browser session. GeoServer still
owns its security filters, local Basic authentication, and OGC authentication.
The separate `geoserver-acl` service owns fine-grained workspace and layer
authorization.

The proxy uses standard reverse-proxy and `X-Forwarded-*` behavior so a future
edge service can replace it without changing GeoServer's public base path.

---

## 1. Responsibilities

1. Terminate browser traffic, run Keycloak OIDC (Authorization Code + **PKCE**).
2. Establish a stateless, encrypted **session cookie** (no server-side store).
3. On every authenticated request, strip inbound identity headers and inject
  trusted identity headers derived from the validated OIDC session before
  forwarding to the internal gateway. The deployed principal is the lower-case
  `email` claim, injected as `sec-username`. The stable `idir_user_guid` claim
  is stored for audit and reference, but is not the deployed principal.
4. Inject `sec-roles` for authenticated OIDC sessions. Configured seed/admin
  principals from `GEOSERVER_ADMIN_PRINCIPALS` receive `OIDC_ROLES`; all other
  OIDC users receive GeoServer's built-in `ROLE_AUTHENTICATED` authority.
  GeoServer's `headerAuth` filter uses the header role source.
5. Reverse-proxy everything else to the internal gateway, **preserving path, query, method,
  body (streamed), and GeoServer cookies** (e.g. `JSESSIONID`).
6. Set `X-Forwarded-*` so GeoServer generates correct absolute URLs.
7. Silent **token refresh** using the refresh token.
8. Pass through **machine-client** auth (HTTP Basic / `authkey` query param) untouched when
  `MACHINE_AUTH_PASSTHROUGH=true`. GeoServer validates those credentials directly.

## 2. Routes the app MUST expose

| Method | Path | Auth | Behavior |
| --- | --- | --- | --- |
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
- **Deployed identity claim -> `sec-username` = lower-case `email`**. This is
  set by Terraform with `USERNAME_CLAIM=email` and
  `USERNAME_LOWERCASE=true`.
- `idir_user_guid` is a separate optional claim used for audit/reference data.
- Changing `USERNAME_CLAIM` changes the GeoServer principal and requires a
  coordinated user, role, ACL, and migration plan.
- Recommended library: [`openid-client`](https://github.com/panva/node-openid-client) (v6) + `express`.

## 4. Header contract with GeoServer (critical)

**Inject (only when a valid OIDC session exists):**

```text
sec-username: <lower-case email>
sec-user-display-name: <display_name>
sec-roles: <OIDC_ROLES for seed/admin principals, otherwise ROLE_AUTHENTICATED>
```

(The display name is optional and is used by the GeoServer UI. The role value is
`OIDC_ROLES` for configured seed/admin principals and `ROLE_AUTHENTICATED` for
all other OIDC users.)

**Always strip from the inbound client request before forwarding (anti-spoofing), regardless of auth state:**

```text
sec-username, sec-user-display-name, sec-roles, sec-*, x-gsc-username, x-gsc-roles, x-gsc-*
```

(Overwrite, never pass through client-supplied values.)

**Set forwarded headers** (use the configured `PUBLIC_ORIGIN`, not client-supplied Host):

```text
X-Forwarded-Host:  <public host>
X-Forwarded-Proto: https
X-Forwarded-Port:  443
X-Forwarded-For:   <client ip>   # append, don't overwrite the chain
```

**Pass through transparently** (both directions): `Cookie` / `Set-Cookie` (so `JSESSIONID` and
GeoServer's Wicket session survive). The proxy's own session cookie uses a distinct name.

> Roles **are sent as a header** in the deployed design. The proxy injects
> `sec-roles`, and `headerAuth` uses `roleSource=Header`. The current Terraform
> setting gives every OIDC-authenticated session `ROLE_ADMINISTRATOR`. The
> built-in XML role service is still used for GeoServer's local user/group data,
> but it is not the source of OIDC roles in this filter configuration.

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

`MACHINE_AUTH_PASSTHROUGH` defaults to `false` in the proxy. Terraform sets it
to `true` for the deployed App Service. When it is enabled, the proxy does not
validate the Basic credential or authkey. It only identifies the request shape
and forwards it. GeoServer must reject invalid credentials and `geoserver-acl`
must reject identities without an appropriate rule.

## 6. Session cookie (stateless)

- Name: `${SESSION_COOKIE_NAME}` (default `gs_sso`), distinct from `JSESSIONID`.
- Encrypted (JWE, dir + A256GCM) or signed-then-encrypted, key from `SESSION_COOKIE_SECRET` (≥32 bytes).
- Flags: `HttpOnly; Secure; SameSite=Lax; Path=/`.
- Payload (keep small - cookies cap at about 4 KB): `sub`, the configured
  principal, `accessExp`, `refreshToken`, and optional display/id-token data.
  **Do not** log tokens.
- The proxy warns at about 3800 bytes with the `session:seal-large` event. A
  browser may silently drop a larger cookie, which looks like a login that does
  not persist.
- Refresh occurs when the access token has 30 seconds or less remaining. The
  proxy writes a replacement cookie. There is no retry of the failed request.
- On refresh failure, the proxy clears its session cookie and applies the
  unauthenticated decision matrix. Browser requests are redirected to login and
  API requests receive `401`.
- The proxy session answers "who is the user?". GeoServer's `JSESSIONID` answers
  "which Wicket UI page/session is active?". Both cookies are required for a
  stateful web UI session.
- The absolute session cap defaults to 12 hours.

## 7. Reverse-proxy requirements

- Target base: `${GATEWAY_ORIGIN}` (scheme+host, **no path**). In the current
  Terraform deployment this is the gateway's VNet-reachable external-ingress
  hostname, `https://gateway.<aca-default-domain>`. It is not the
  `gateway.internal.<aca-default-domain>` hostname. Preserve the full incoming
  path+query.
- **Stream** request and response bodies (large WMS rasters / GetCapabilities) — do not buffer.
- Preserve method and headers except hop-by-hop (`Connection`, `Keep-Alive`, `Transfer-Encoding`,
  `Upgrade`, `Proxy-*`, `TE`, `Trailer`) and the stripped `sec-*`/`x-gsc-*`.
- TLS to gateway: verify normally. `GATEWAY_TLS_INSECURE` defaults to `false`
  and must remain false in production.
- Default timeouts are connect 5s and read 60s. Terraform overrides these to
  90s and 180s to allow Container Apps cold starts and large OWS responses.
  Return `502` on upstream failure.
- WebSockets: not required (the 3.0 WebMVC gateway dropped WS routing).
- `app.set('trust proxy', true)` — App Service / Front Door sits in front.

## 8. Environment variables (injected by Terraform / App Service)

| Var | Example | Notes |
| --- | --- | --- |
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
| `GATEWAY_ORIGIN` | `https://gateway.<env-domain>` | VNet-reachable ACA gateway base (no path). The current gateway has external ingress on the environment's internal load balancer. |
| `PUBLIC_ORIGIN` | `https://<public-host>` | For `X-Forwarded-Host` + redirect building. |
| `GS_IDENTITY_HEADER` | `sec-username` | Header name injected to GeoServer. Must match `principalHeaderAttribute` in `headerAuth`. |
| `GS_ROLES_HEADER` | `sec-roles` | Header name for roles. Must match `rolesHeaderAttribute` in `headerAuth`. |
| `OIDC_ROLES` | `ROLE_ADMINISTRATOR` | Comma-separated privileged roles injected for `GEOSERVER_ADMIN_PRINCIPALS`. |
| `GEOSERVER_ADMIN_PRINCIPALS` | configured seed email(s) | Comma-separated lower-case OIDC principals that retain `OIDC_ROLES` and can view `/admin/idir-users`. |
| `USERNAME_CLAIM` | `email` | Keycloak claim extracted and injected as `sec-username`. |
| `USERNAME_LOWERCASE` | `true` in Terraform | Lower-cases the configured principal. |
| `USER_GUID_CLAIM` | `idir_user_guid` | Optional stable IDIR identifier retained for audit/reference. |
| `DISPLAY_NAME_HEADER` | `sec-user-display-name` | Header name for the user's display name (for UI). |
| `DISPLAY_NAME_CLAIM` | `display_name` | Keycloak claim extracted → injected as display-name header value. |
| `MACHINE_AUTH_PASSTHROUGH` | `true` | Enables §5 rule 2. |
| `GATEWAY_TLS_INSECURE` | `false` | |
| `GATEWAY_CONNECT_TIMEOUT_MS` | `5000` | Terraform sets `90000` for cold starts. |
| `GATEWAY_READ_TIMEOUT_MS` | `60000` | Terraform sets `180000` for large responses. |
| `DEBUG_HEADERS` | `true` | Terraform sets `false`; controls sanitized header logging. |
| `DEBUG_UNSAFE_HEADERS` | `false` | Must stay false. It can expose cookies and credentials. |
| `LOG_LEVEL` | `info` | Never log tokens/secrets. |

## 9. Dockerfile contract

- Multi-stage: builder and runtime use `node:24-alpine`, matching `mise.toml`.
- Run as **non-root** user.
- `EXPOSE 8080`; app listens on `0.0.0.0:$PORT`.
- `HEALTHCHECK` → `GET /healthz`.
- No secrets baked into the image. `.dockerignore` excludes `node_modules`, `.env`, tests.
- Publish to **GHCR**: `ghcr.io/<org>/<repo>:<tag>` (and `:sha-<short>`); multi-arch `linux/amd64`
  (App Service Linux). Sign if your supply-chain policy requires.

### Reference Dockerfile skeleton

```dockerfile
# build
FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build            # if TS; omit for plain JS

# runtime
FROM node:24-alpine
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
- GeoServer: request-header pre-auth filter reading `sec-username` and
  `sec-roles`, the built-in XML role/user-group service, local Basic auth,
  `auth-key` extension, and ACL.
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
- Confirm `email` is in the ID token. `idir_user_guid` and `display_name` are
  optional in the current proxy, but are required if the corresponding audit or
  display behavior is expected.

## 13. Internal gateway trust boundary

The public App Service is the intended edge. It connects to the gateway through
the spoke VNet. The Container Apps environment uses an internal load balancer,
so the gateway hostname is not a public internet endpoint even though the
gateway Container App uses `external = true` within that environment.

The gateway routes OWS, REST, GWC, and Web UI traffic to internal services and
applies the `SharedAuth` filter to those routes. The gateway receives the
identity headers from the Node proxy and forwards the request to GeoServer.

The proxy is the component that removes client-supplied `sec-*` and `x-gsc-*`
headers. Any path that can reach the gateway without that proxy must be treated
as a separate trusted network path and must be tested. Do not describe the
gateway as internet-public merely because its ACA ingress flag is `external`.

## 14. Keycloak troubleshooting

If login fails at the callback:

1. Check the configured `OIDC_REDIRECT_URI` against the Keycloak client's valid
  redirect URI. It must include `/auth/callback`.
2. Check the post-logout URI and web origin.
3. Check the proxy log for `oidc:principal-claim-missing` and
  `oidc:callback-claims`.
4. Confirm that `email` is an ID-token claim when `USERNAME_CLAIM=email`.
5. Confirm that `display_name` and `idir_user_guid` are present if the UI or
  audit view requires them.

The proxy validates discovery metadata, the authorization code, PKCE, state,
nonce, issuer, audience, expiry, and the ID-token signature. It does not accept
an unvalidated identity header from a client.

## 15. Admin bootstrap and recovery

The security script attempts to create `ADMIN_PRINCIPAL` in GeoServer's default
user/group service and assign `ROLE_ADMINISTRATOR`. If the variable is empty or
the assignment fails, the built-in `admin` account remains the recovery account.

After a failed bootstrap, use the built-in admin credentials from Key Vault,
confirm that `headerAuth` and `sec-roles` are configured, create or update the
OIDC principal in the default user/group service, and assign the required role.
Record the action and rerun the verification section of
`configure-geoserver-security.sh`.

## 16. Native GeoServer OIDC alternative

GeoServer has an OIDC extension, but this deployment uses the Node proxy because
the proxy provides the public edge, browser session cookie, Keycloak callback,
machine-auth passthrough, header anti-spoofing, and a single gateway entry point
for the GeoServer Cloud services.

Replacing the proxy with native GeoServer OIDC would require a compatibility
test against the pinned GeoServer Cloud images. The test must cover the Web UI,
REST, WMS/WFS/WCS/WPS/GWC, multiple replicas, `JSESSIONID`, Keycloak claims,
role mapping, machine clients, and direct gateway access. The replacement must
also preserve the internal-only network boundary and the current `geoserver-acl`
authorization model.
