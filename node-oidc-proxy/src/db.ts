/**
 * Lightweight pg pool for user auto-registration + the admin reference view.
 *
 * On every successful OIDC login the proxy upserts the user's IDIR GUID, email
 * (the GeoServer principal) and display name into gssec.user_display_names. The
 * table is keyed on the immutable GUID, so the row survives an email/name change.
 *
 * The pool is optional — if PGCONFIG_HOST is not set the module is a no-op.
 * DB failures are logged as warnings and never propagate to the OIDC callback.
 *
 * DEBUG: every upsert logs whether the DB is configured, the row written, and
 * the full error on failure (these calls are fire-and-forget, so without logs a
 * failure here is completely invisible).
 */
import pg from 'pg';
import { config } from './config.ts';
import { logger } from './logger.ts';

let pool: pg.Pool | undefined;

function getPool(): pg.Pool | undefined {
  const { host, database, username, password } = config.db;
  if (!host || !database || !username || !password) return undefined;

  if (!pool) {
    pool = new pg.Pool({
      host,
      port: config.db.port,
      database,
      user: username,
      password,
      ssl: { rejectUnauthorized: false }, // private endpoint, no public CA needed
      max: 2,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 5_000,
    });
    pool.on('error', (err: Error) => {
      logger.error({ ev: 'db:pool-error', err: err.message }, 'pg pool background error');
    });
    logger.info({ ev: 'db:pool-init', host, port: config.db.port, database }, 'pg pool initialised for user auto-registration');
  }
  return pool;
}

/**
 * Upsert the user into gssec.user_display_names, keyed on the stable IDIR GUID.
 * `email` is the GeoServer principal (sec-username); `displayName` is the
 * friendly label. Fire-and-forget — caller should void this; never awaited on
 * the hot path. Skips silently if the GUID is missing (the GUID is the PK).
 */
export async function upsertUser(
  guid: string | undefined,
  email: string,
  displayName: string | undefined,
): Promise<void> {
  const p = getPool();
  if (!p) {
    logger.debug({ ev: 'db:upsert-skip', reason: 'db-not-configured', email }, 'upsertUser skipped — PGCONFIG_* not set');
    return;
  }
  if (!guid) {
    logger.warn({ ev: 'db:upsert-skip', reason: 'no-guid', email }, 'upsertUser skipped — no IDIR GUID claim (the PK); check USER_GUID_CLAIM / token mapper');
    return;
  }
  try {
    const result = await p.query(
      `INSERT INTO gssec.user_display_names (idir_user_guid, email, display_name)
       VALUES ($1, $2, $3)
       ON CONFLICT (idir_user_guid)
       DO UPDATE SET email = EXCLUDED.email, display_name = EXCLUDED.display_name`,
      [guid, email, displayName ?? email],
    );
    logger.info(
      { ev: 'db:upsert-ok', guid, email, rowCount: result.rowCount },
      'upserted user in gssec.user_display_names',
    );
  } catch (err) {
    logger.warn(
      { ev: 'db:upsert-error', err: (err as Error).message, guid, email },
      'failed to upsert user into gssec — roles can still be assigned manually',
    );
  }
}

export interface IdirUser {
  guid: string;
  email: string | null;
  displayName: string;
}

/**
 * List all registered IDIR users (GUID + email + display name) for the admin
 * reference view. Returns [] when the DB is not configured.
 */
export async function listUsers(): Promise<IdirUser[]> {
  const p = getPool();
  if (!p) return [];
  const res = await p.query(
    `SELECT idir_user_guid, email, display_name
       FROM gssec.user_display_names
      ORDER BY display_name`,
  );
  logger.debug({ ev: 'db:list-users', count: res.rowCount }, 'listed gssec.user_display_names');
  return res.rows.map((r) => ({
    guid: r.idir_user_guid as string,
    email: (r.email as string | null) ?? null,
    displayName: r.display_name as string,
  }));
}
