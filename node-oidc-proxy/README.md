# Node OIDC Edge Proxy

A small, stateless **public-facing reverse proxy** that sits in front of the
internal **GeoServer Cloud** gateway. It runs the BC Gov Keycloak OIDC
(Authorization Code + **PKCE**) login, holds an **encrypted, server-store-free
cookie session**, and on every request injects a trusted `sec-username` identity
header into the upstream before reverse-proxying.

It is a **drop-in** that can later be replaced by Azure Front Door Premium
without changing GeoServer — it relies only on standard reverse-proxy +
`X-Forwarded-*` semantics.

> Implements the *Node OIDC Edge Proxy — Container Contract*. Section references
> below (§n) map to that contract.

## Stack — all current-latest (June 2026)

| Dependency | Version | Role |
|---|---|---|
| Node.js | **24 LTS** | Runtime (Docker base + local) |
| `express` | `^5.2.1` | HTTP framework |
| `openid-client` | `^6.8.4` | Keycloak OIDC relying party (functional API) |
| `jose` | `^6.2.3` | JWE session sealing (`dir` + `A256GCM`) |
| `cookie` | `^1.0.2` | Cookie parse/serialize |
| `pino` | `^10.3.1` | Structured JSON logging |
| `typescript` (dev) | `^6.0.3` | Build / typecheck |
| `@types/node` (dev) | `^24.x` | Node typings — **pinned to the Node 24 runtime major** |
| `@types/express` (dev) | `^5.0.3` | Express 5 typings |

No legacy/transitional packages: there is **no** `http-proxy` /
`http-proxy-middleware` (the proxy is built on Node's native `http`/`https`
streaming), **no** `cookie-parser`, **no** `dotenv`, and **no** `tsx` (Node 24's
built-in TypeScript execution powers `npm run dev`).

> Why `@types/node@24` and not the newer `26.x`? The published `@types/node` 26
> line describes the **unreleased** Node 26 API surface. Typings must match the
> runtime that actually runs the code (Node 24 LTS), so 24.x *is* the latest
> correct version — not an older one. Bump both together when you move to Node 26.

## Project layout

```
src/
  config.ts    Env parsing + validation (fail-fast at boot)
  logger.ts    pino logger with token/secret redaction
  jwe.ts       Shared JWE seal/open primitives (dir + A256GCM)
  session.ts   Stateless session cookie (read / seal / clear)
  oidc.ts      Discovery, login, callback, refresh, logout (openid-client v6)
  proxy.ts     Native streaming reverse proxy + header contract
  app.ts       Express routes + unauthenticated decision matrix (§5)
  server.ts    Entry point (discovery → listen → graceful shutdown)
Dockerfile     Multi-stage, non-root, HEALTHCHECK
```

## Routes (§2)

| Method | Path | Auth | Behavior |
|---|---|---|---|
| GET | `/healthz` | none | `200 {"status":"ok"}` — health probe |
| GET | `/auth/login` | none | PKCE + state + nonce → 302 to Keycloak |
| GET | `/auth/callback` | none | Validate, exchange code, set session, 302 to `returnTo` |
| GET | `/auth/logout` | none | Clear session, 302 to Keycloak end-session |
| GET | `/` | none | Convenience 302 → `/geoserver/cloud/web/` |
| ALL | `/*` | session | Valid session → inject + proxy; else decision matrix |

## Getting started

Requires **Node.js ≥ 24**.

```bash
cp .env.example .env          # fill in secrets (or inject via App Service)
npm install                   # generates package-lock.json on first run
npm run dev                   # watch mode (Node strips TypeScript directly)
```

Build & run production output:

```bash
npm run build                 # tsc → dist/
npm start                     # node dist/server.js
npm run typecheck             # tsc --noEmit (CI gate)
```

> First-time setup runs `npm install` to produce `package-lock.json`. Commit
> that lockfile — the Docker image build uses `npm ci` for reproducibility.

## Docker

```bash
docker build -t node-oidc-edge-proxy .
docker run --rm -p 8080:8080 --env-file .env node-oidc-edge-proxy
```

Publish to GHCR (multi-arch `linux/amd64` for App Service Linux):

```bash
docker buildx build --platform linux/amd64 \
  -t ghcr.io/<org>/<repo>:<tag> \
  -t ghcr.io/<org>/<repo>:sha-<short> \
  --push .
```

## Environment variables (§8)

See `.env.example`. Required: `OIDC_ISSUER`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URI`, `SESSION_COOKIE_SECRET` (≥32 bytes),
`GATEWAY_ORIGIN`, `PUBLIC_ORIGIN`. The app **fails fast at boot** if a required
variable is missing or the secret is too short.

## Header contract with GeoServer (§4)

- **Injected** (only with a valid session): `sec-username: <preferred_username>`.
- **Always stripped** from inbound requests (anti-spoofing, any auth state):
  `sec-*`, `x-gsc-*` — overwritten, never passed through.
- **Forwarded** from `PUBLIC_ORIGIN` (never client `Host`):
  `X-Forwarded-Host/Proto/Port`; `X-Forwarded-For` is appended to the chain.
- `Cookie` / `Set-Cookie` pass through transparently so `JSESSIONID` and the
  Wicket session survive. The proxy's own session cookie uses a distinct name.

## Security (§10)

PKCE (S256); `state` + `nonce` validated; ID token signature/`iss`/`aud`/`exp`
validated by `openid-client`. Cookies are `HttpOnly; Secure; SameSite=Lax`.
Redirect URIs are built from configured env, never from client `Host`. Tokens
and secrets are never logged (pino redaction + careful call sites).

## Not in scope

WebSockets (the 3.0 WebMVC gateway dropped WS routing). Role headers — GeoServer
resolves roles from its JDBC role service keyed on `sec-username`; `sec-roles`
is reserved for a future header-based source.
