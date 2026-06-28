/**
 * Low-level JWE seal/open primitives (dir + A256GCM) shared by the session
 * cookie and the short-lived login-transaction cookie. One derived key, one
 * algorithm pair, used everywhere.
 */
import { createHash } from 'node:crypto';
import { EncryptJWT, jwtDecrypt, type JWTPayload } from 'jose';
import { config } from './config.ts';

const ENC = 'A256GCM' as const;
const ALG = 'dir' as const;

/**
 * 256-bit key derived from SESSION_COOKIE_SECRET. Hashing normalises any
 * >=32-byte secret to the exact length A256GCM requires.
 */
const key = createHash('sha256').update(config.session.secret, 'utf8').digest();

/**
 * Encrypt a payload into a compact JWE.
 * @param expiration jose-style expiry (e.g. "12h", "600s").
 */
export async function seal(payload: JWTPayload, expiration: string): Promise<string> {
  return new EncryptJWT(payload)
    .setProtectedHeader({ alg: ALG, enc: ENC })
    .setIssuedAt()
    .setExpirationTime(expiration)
    .encrypt(key);
}

/** Decrypt and validate a JWE. Throws on tamper / expiry / wrong key. */
export async function open(token: string): Promise<JWTPayload> {
  const { payload } = await jwtDecrypt(token, key, {
    contentEncryptionAlgorithms: [ENC],
    keyManagementAlgorithms: [ALG],
  });
  return payload;
}
