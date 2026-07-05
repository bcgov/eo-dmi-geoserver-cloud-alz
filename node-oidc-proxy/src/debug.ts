/**
 * Debug instrumentation toolkit — sanitised header / cookie logging shared by
 * the global HTTP request-response middleware (app.ts) and the upstream proxy
 * hop (proxy.ts).
 *
 * WHY THIS EXISTS
 * ---------------
 * The IDIR "logged-in state doesn't stick" problem can go wrong at any of FOUR
 * hops, and the browser dev tools can only see hops 1 and 4:
 *
 *     (1) browser  → proxy     [inbound request]      app.ts middleware
 *     (2) proxy    → gateway   [upstream request]     proxy.ts
 *     (3) gateway  → proxy     [upstream response]    proxy.ts
 *     (4) proxy    → browser   [final response]       app.ts middleware
 *
 * Every log line carries a short `reqId` so you can `grep` one browser request
 * end-to-end across all four hops and see the exact hop where the identity
 * header or the JSESSIONID session state goes bad.
 *
 * SAFETY
 * ------
 * By default, secret-bearing VALUES are MASKED while their NAME, length and
 * structural attributes stay visible:
 *   - the encrypted session cookie + login-tx cookie  → masked
 *   - Authorization / Proxy-Authorization              → scheme kept, creds masked
 *   - every other cookie value (incl. JSESSIONID)      → masked (prefix/suffix kept
 *                                                         so you can still correlate)
 * The identity headers we actually need to verify — `sec-username` and
 * `sec-user-display-name` — are shown IN FULL. They are an email / display name /
 * GUID, not secrets.
 *
 * For a controlled test run where you want to see raw values too, set
 * DEBUG_UNSAFE_HEADERS=true (this also disables the pino redaction backstop in
 * logger.ts). Never leave that on in a shared/prod environment.
 */
import crypto from 'node:crypto';
import type { Request, Response } from 'express';
import type { IncomingHttpHeaders, OutgoingHttpHeaders } from 'node:http';
import { config } from './config.ts';
import { logger } from './logger.ts';

// ---------------------------------------------------------------------------
// Per-request correlation id + timing (no global type augmentation; WeakMap).
// ---------------------------------------------------------------------------
interface ReqMeta {
  id: string;
  start: number;
}
const meta = new WeakMap<Request, ReqMeta>();

/** Stable per-request id (8 hex chars). Assigned lazily, reused across hops. */
export function getReqId(req: Request): string {
  let m = meta.get(req);
  if (!m) {
    m = { id: crypto.randomUUID().slice(0, 8), start: Date.now() };
    meta.set(req, m);
  }
  return m.id;
}

/** Milliseconds since this request was first seen (−1 if never registered). */
export function reqElapsedMs(req: Request): number {
  const m = meta.get(req);
  return m ? Date.now() - m.start : -1;
}

// ---------------------------------------------------------------------------
// Value masking + header / cookie sanitisation.
// ---------------------------------------------------------------------------

/** Header names whose VALUE is a credential and must be masked. */
const SECRET_HEADERS = new Set(['authorization', 'proxy-authorization']);

/** Mask a value: keep length + a short prefix/suffix so it can be correlated. */
export function mask(value: string): string {
  if (config.debug.unsafe) return value;
  const len = value.length;
  if (len === 0) return '«empty»';
  if (len <= 8) return `«masked ${len}b»`;
  return `${value.slice(0, 4)}…${value.slice(-2)} «masked ${len}b»`;
}

export interface CookieSummary {
  count: number;
  names: string[];
  /** True if any JSESSIONID* cookie is present (the GeoServer webui session). */
  jsessionid: boolean;
  /** True if the proxy's own session cookie is present. */
  sessionCookie: boolean;
  /** name → masked value (so JSESSIONID can be correlated request-to-request). */
  cookies: Record<string, string>;
}

/** Break a Cookie header into names + flags + masked values. */
export function summarizeCookie(cookieHeader: string | undefined): CookieSummary {
  const summary: CookieSummary = {
    count: 0,
    names: [],
    jsessionid: false,
    sessionCookie: false,
    cookies: {},
  };
  if (!cookieHeader) return summary;

  const sessName = config.session.cookieName.toLowerCase();
  for (const part of cookieHeader.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    const name = part.slice(0, idx).trim();
    if (!name) continue;
    const val = part.slice(idx + 1).trim();
    summary.names.push(name);
    summary.cookies[name] = mask(val);
    if (/^JSESSIONID/i.test(name)) summary.jsessionid = true;
    if (name.toLowerCase() === sessName) summary.sessionCookie = true;
  }
  summary.count = summary.names.length;
  return summary;
}

export interface SetCookieSummary {
  name: string;
  value: string;
  /** True when this Set-Cookie clears the cookie (logout / refresh-fail). */
  cleared: boolean;
  /** Attributes: Path, HttpOnly, Secure, SameSite, Max-Age, Domain, Expires. */
  attrs: string[];
  isJsessionid: boolean;
}

/** Break a Set-Cookie header (string | array) into structured masked entries. */
export function summarizeSetCookie(
  setCookie: string | string[] | undefined,
): SetCookieSummary[] {
  if (!setCookie) return [];
  const arr = Array.isArray(setCookie) ? setCookie : [setCookie];
  return arr.map((sc) => {
    const segs = sc.split(';').map((s) => s.trim());
    const nv = segs[0] ?? '';
    const attrs = segs.slice(1);
    const eq = nv.indexOf('=');
    const name = eq === -1 ? nv : nv.slice(0, eq);
    const val = eq === -1 ? '' : nv.slice(eq + 1);
    const cleared =
      val === '' ||
      attrs.some((a) => /^Max-Age=0$/i.test(a)) ||
      attrs.some((a) => /^Expires=Thu, 01 Jan 1970/i.test(a));
    return {
      name,
      value: mask(val),
      cleared,
      attrs,
      isJsessionid: /^JSESSIONID/i.test(name),
    };
  });
}

/** Sanitise a header bag for logging: mask secrets, summarise cookies, keep the rest. */
export function sanitizeHeaders(
  headers: IncomingHttpHeaders | OutgoingHttpHeaders | Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(headers)) {
    if (v === undefined) continue;
    const lk = k.toLowerCase();
    if (lk === 'cookie') {
      out[k] = summarizeCookie(Array.isArray(v) ? v.join('; ') : String(v));
      continue;
    }
    if (lk === 'set-cookie') {
      out[k] = summarizeSetCookie(v as string | string[]);
      continue;
    }
    if (SECRET_HEADERS.has(lk)) {
      const s = Array.isArray(v) ? v.join(',') : String(v);
      const sp = s.indexOf(' ');
      const scheme = sp === -1 ? s : s.slice(0, sp);
      out[k] = config.debug.unsafe ? s : `${scheme} ${mask(sp === -1 ? '' : s.slice(sp + 1))}`;
      continue;
    }
    // Everything else — including the identity headers (sec-username,
    // sec-user-display-name) — is shown in full. They are what we want to see.
    out[k] = v;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Express middleware: log hop (1) inbound request + hop (4) final response.
// ---------------------------------------------------------------------------

/** Paths we never log (health probes hammer this and carry nothing useful). */
const SKIP_PATHS = new Set(['/healthz', '/favicon.ico']);

/**
 * Global request/response logger. Emitted at `info` (visible at the default log
 * level) and gated by DEBUG_HEADERS so it can be turned off later without a
 * redeploy. Logs the FULL sanitised header set for both the inbound browser
 * request and the final response sent back to the browser, plus status + timing.
 */
export function requestLogging() {
  return (req: Request, res: Response, next: () => void): void => {
    if (SKIP_PATHS.has(req.path)) {
      next();
      return;
    }
    const reqId = getReqId(req);

    if (config.debug.headers) {
      const cookies = summarizeCookie(
        typeof req.headers.cookie === 'string' ? req.headers.cookie : undefined,
      );
      logger.info(
        {
          reqId,
          ev: 'http:request',
          method: req.method,
          url: req.originalUrl,
          remoteIp: req.socket.remoteAddress ?? null,
          accept: req.headers.accept ?? null,
          jsessionidInbound: cookies.jsessionid,
          sessionCookiePresent: cookies.sessionCookie,
          headers: sanitizeHeaders(req.headers),
        },
        'http:request',
      );
    }

    res.on('finish', () => {
      if (!config.debug.headers) return;
      const headers = res.getHeaders();
      const setCookie = summarizeSetCookie(
        headers['set-cookie'] as string | string[] | undefined,
      );
      logger.info(
        {
          reqId,
          ev: 'http:response',
          method: req.method,
          url: req.originalUrl,
          status: res.statusCode,
          durationMs: reqElapsedMs(req),
          location: (headers['location'] as string | undefined) ?? null,
          setsJsessionid: setCookie.some((c) => c.isJsessionid),
          setCookie,
          headers: sanitizeHeaders(headers as Record<string, unknown>),
        },
        'http:response',
      );
    });

    next();
  };
}
