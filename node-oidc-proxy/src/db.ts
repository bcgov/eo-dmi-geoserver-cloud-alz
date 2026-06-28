/**
 * Lightweight pg pool for user auto-registration.
 *
 * On every successful OIDC login the proxy upserts the user's IDIR GUID and
 * display name into gssec.user_display_names so the GeoServer admin can see
 * who has logged in and assign roles to them without needing Keycloak access.
 *
 * The pool is optional — if PGCONFIG_HOST is not set the module is a no-op.
 * DB failures are logged as warnings and never propagate to the OIDC callback.
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
      logger.error({ err: err.message }, 'pg pool background error');
    });
    logger.info({ host, database }, 'pg pool initialised for user auto-registration');
  }
  return pool;
}

/**
 * Upsert the user into gssec.user_display_names.
 * Fire-and-forget — caller should void this; never awaited on the hot path.
 */
export async function upsertUser(guid: string, displayName: string | undefined): Promise<void> {
  const p = getPool();
  if (!p) return;
  try {
    await p.query(
      `INSERT INTO gssec.user_display_names (idir_user_guid, display_name)
       VALUES ($1, $2)
       ON CONFLICT (idir_user_guid) DO UPDATE SET display_name = EXCLUDED.display_name`,
      [guid, displayName ?? guid],
    );
    logger.debug({ guid }, 'upserted user in gssec.user_display_names');
  } catch (err) {
    logger.warn({ err: (err as Error).message, guid }, 'failed to upsert user into gssec — roles can still be assigned manually');
  }
}
