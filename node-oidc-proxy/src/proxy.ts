/**
 * Streaming reverse proxy to the internal GeoServer Cloud gateway.
 *
 * Responsibilities (contract §4, §7):
 *  - Strip spoofable identity headers from the inbound request, ALWAYS.
 *  - Optionally inject the trusted identity header from a validated session.
 *  - Set X-Forwarded-* from the configured public origin (not client Host).
 *  - Stream request and response bodies (large WMS rasters) — never buffer.
 *  - Preserve method, path, query, and cookies — INCLUDING JSESSIONID_webui, so
 *    the Wicket web UI keeps its server-side session and stateful navigation
 *    works. The pre-auth filter re-evaluates sec-username on every request and
 *    re-authenticates if the session principal differs, so there is no need to
 *    strip the session cookie. (The earlier "anonymous shadowing" was actually
 *    the IDENTITY_HEADER name collision, now fixed via GS_IDENTITY_HEADER.)
 *  - Verify gateway TLS; map upstream failures to 502.
 *
 * DEBUG: this module logs hops (2) proxy→gateway and (3) gateway→proxy with the
 * full sanitised header set and a per-request reqId (see debug.ts). The key
 * boolean to watch is `jsessionidStripped`: inbound carried a JSESSIONID and we
 * removed it before forwarding. If that is false while an identity is injected,
 * the stale-anonymous-session shadowing is back.
 */
import http from 'node:http';
import https from 'node:https';
import type { IncomingHttpHeaders } from 'node:http';
import type { Request, Response } from 'express';
import { config } from './config.ts';
import { logger } from './logger.ts';
import {
  getReqId,
  reqElapsedMs,
  sanitizeHeaders,
  summarizeCookie,
  summarizeSetCookie,
} from './debug.ts';

/** Hop-by-hop headers must not be forwarded (RFC 7230 §6.1). */
const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);

/** Identity-bearing prefixes that clients must never be able to spoof. */
const SPOOFABLE_PREFIXES = ['sec-', 'x-gsc-'];

const gatewayUrl = new URL(config.gateway.origin);
const isHttps = gatewayUrl.protocol === 'https:';
const transport = isHttps ? https : http;
const publicHost = new URL(config.publicOrigin).host;

// Reuse a keep-alive agent for upstream connections.
const agent = isHttps
  ? new https.Agent({ keepAlive: true, rejectUnauthorized: !config.gateway.tlsInsecure })
  : new http.Agent({ keepAlive: true });

function isSpoofable(name: string): boolean {
  return SPOOFABLE_PREFIXES.some((prefix) => name.startsWith(prefix));
}

/**
 * The trusted identity injected on an authenticated request:
 *  - username:    the principal (email) → identityHeader (GeoServer role lookups).
 *  - displayName: human-readable label → displayNameHeader (GeoServer UI only).
 * Both are derived from the validated session, never from client input.
 */
export interface InjectedIdentity {
  username: string;
  displayName?: string;
}

/** Coerce a header value (string | string[] | undefined) to a string for inspection. */
function headerToString(value: string | string[] | undefined): string | undefined {
  if (value === undefined) return undefined;
  return Array.isArray(value) ? value.join('; ') : value;
}

/**
 * Build the outbound header set: copy inbound headers minus hop-by-hop and
 * spoofable identity headers, then set forwarded headers and (optionally) the
 * trusted identity headers.
 */
function buildHeaders(req: Request, identity: InjectedIdentity | undefined): IncomingHttpHeaders {
  const out: IncomingHttpHeaders = {};

  for (const [name, value] of Object.entries(req.headers)) {
    const lower = name.toLowerCase();
    if (HOP_BY_HOP.has(lower)) continue;
    if (isSpoofable(lower)) continue; // overwrite, never pass through
    if (lower === 'host') continue; // set explicitly below
    // Forward cookies — including JSESSIONID_webui — UNCHANGED so the Wicket web
    // UI keeps its server-side session and stateful page navigation works.
    if (value !== undefined) out[lower] = value;
  }

  // Upstream sees the internal gateway host.
  out['host'] = gatewayUrl.host;

  // Forwarded headers from configured public origin, not client-supplied Host.
  out['x-forwarded-host'] = publicHost;
  out['x-forwarded-proto'] = 'https';
  out['x-forwarded-port'] = '443';

  // Append this hop's client IP to the existing chain (don't overwrite).
  const clientIp = req.socket.remoteAddress ?? '';
  const priorXff = req.headers['x-forwarded-for'];
  const chain = Array.isArray(priorXff) ? priorXff.join(', ') : priorXff;
  out['x-forwarded-for'] = chain ? `${chain}, ${clientIp}` : clientIp;

  // Inject the trusted identity headers only for authenticated sessions.
  // The display-name header is optional (the claim may be absent); the identity
  // header (principal/email) is what GeoServer authenticates and resolves roles from.
  if (identity) {
    out[config.identityHeader] = identity.username;
    if (identity.displayName) {
      out[config.displayNameHeader] = identity.displayName;
    }
  }

  return out;
}

/**
 * Proxy the current request to the gateway, streaming both directions.
 * @param injectUsername    when set, inject the trusted identity header (principal).
 * @param injectDisplayName optional human-readable name for the display header.
 */
export function proxy(
  req: Request,
  res: Response,
  injectUsername?: string,
  injectDisplayName?: string,
): void {
  const reqId = getReqId(req);
  const identity: InjectedIdentity | undefined = injectUsername
    ? { username: injectUsername, displayName: injectDisplayName }
    : undefined;
  const headers = buildHeaders(req, identity);

  // ---- Hop (2): proxy → gateway. What we are actually sending upstream. ----
  const inboundCookie = summarizeCookie(headerToString(req.headers.cookie));
  const outboundCookie = summarizeCookie(headerToString(headers.cookie));
  const jsessionidStripped = inboundCookie.jsessionid && !outboundCookie.jsessionid;

  logger.info(
    {
      reqId,
      ev: 'proxy:upstream-request',
      method: req.method,
      upstream: `${gatewayUrl.origin}${req.originalUrl}`,
      // Identity headers shown IN FULL — this is the value GeoServer authenticates.
      injected: identity
        ? {
            [config.identityHeader]: identity.username,
            ...(identity.displayName ? { [config.displayNameHeader]: identity.displayName } : {}),
          }
        : null,
      jsessionidInbound: inboundCookie.jsessionid,
      jsessionidForwarded: outboundCookie.jsessionid,
      // THE key signal: did we successfully strip a stale webui session cookie?
      jsessionidStripped,
      ...(config.debug.headers ? { headers: sanitizeHeaders(headers) } : {}),
    },
    'proxy:upstream-request',
  );

  // Typed as https options (a superset of http) so the http|https union call
  // below type-checks cleanly.
  const options: https.RequestOptions = {
    protocol: gatewayUrl.protocol,
    hostname: gatewayUrl.hostname,
    port: gatewayUrl.port || (isHttps ? 443 : 80),
    method: req.method,
    path: req.originalUrl, // full path + query, unmodified
    headers,
    agent,
  };

  const upstream = transport.request(options, (upstreamRes) => {
    clearTimeout(connectTimer);

    // ---- Hop (3): gateway → proxy. What GeoServer responded with. ----
    const setCookie = summarizeSetCookie(upstreamRes.headers['set-cookie']);
    logger.info(
      {
        reqId,
        ev: 'proxy:upstream-response',
        method: req.method,
        upstreamPath: req.originalUrl,
        status: upstreamRes.statusCode ?? null,
        durationMs: reqElapsedMs(req),
        contentType: upstreamRes.headers['content-type'] ?? null,
        // For the OIDC dance + post-login redirects, the Location chain matters.
        location: upstreamRes.headers['location'] ?? null,
        // Does GeoServer hand back a fresh JSESSIONID_webui on this response?
        setsJsessionid: setCookie.some((c) => c.isJsessionid),
        setCookie,
        ...(config.debug.headers ? { headers: sanitizeHeaders(upstreamRes.headers) } : {}),
      },
      'proxy:upstream-response',
    );

    // Copy status + response headers, dropping hop-by-hop. Set-Cookie passes
    // through so GeoServer's JSESSIONID_webui is refreshed in the browser.
    const resHeaders: Record<string, string | string[]> = {};
    for (const [name, value] of Object.entries(upstreamRes.headers)) {
      if (HOP_BY_HOP.has(name.toLowerCase())) continue;
      if (value !== undefined) resHeaders[name] = value;
    }
    res.writeHead(upstreamRes.statusCode ?? 502, resHeaders);
    upstreamRes.pipe(res);
  });

  // Connect timeout: fail fast if the socket never establishes / responds.
  const connectTimer = setTimeout(() => {
    upstream.destroy(new Error('upstream connect timeout'));
  }, config.gateway.connectTimeoutMs);

  // Idle/read timeout once connected.
  upstream.setTimeout(config.gateway.readTimeoutMs, () => {
    upstream.destroy(new Error('upstream read timeout'));
  });

  upstream.on('error', (err) => {
    clearTimeout(connectTimer);
    logger.warn(
      { reqId, ev: 'proxy:upstream-error', err: err.message, path: req.path, durationMs: reqElapsedMs(req) },
      'upstream proxy error',
    );
    if (!res.headersSent) {
      res.status(502).json({ error: 'bad_gateway' });
    } else {
      res.destroy();
    }
  });

  // Stream the request body (if any) to the upstream. No buffering.
  req.pipe(upstream);

  // If the client disconnects mid-flight, tear down the upstream request.
  res.on('close', () => {
    clearTimeout(connectTimer);
    upstream.destroy();
  });
}
