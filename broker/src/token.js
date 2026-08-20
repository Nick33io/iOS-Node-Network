/**
 * Short-lived device tokens: `base64url(payload).base64url(signature)` where
 * the signature is HMAC-SHA256 over the encoded payload using the broker's
 * signing secret. Stateless — any broker instance holding the secret can
 * verify a token any instance minted.
 */

import crypto from "node:crypto";

/**
 * Constant-time string comparison. Both inputs are hashed first so that
 * length differences do not short-circuit; the final comparison is
 * crypto.timingSafeEqual over equal-length digests.
 *
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
export function constantTimeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const ha = crypto.createHash("sha256").update(a, "utf8").digest();
  const hb = crypto.createHash("sha256").update(b, "utf8").digest();
  return crypto.timingSafeEqual(ha, hb);
}

/**
 * @param {object} opts
 * @param {string} opts.deviceId
 * @param {string} opts.secret
 * @param {number} opts.ttlMs
 * @param {number} [opts.now] milliseconds since epoch; defaults to Date.now()
 * @returns {{ token: string, expiresAt: number }}
 */
export function signToken({ deviceId, secret, ttlMs, now = Date.now() }) {
  const expiresAt = now + ttlMs;
  const payload = Buffer.from(JSON.stringify({ deviceId, exp: expiresAt }), "utf8").toString(
    "base64url",
  );
  const signature = crypto.createHmac("sha256", secret).update(payload, "utf8").digest("base64url");
  return { token: `${payload}.${signature}`, expiresAt };
}

/**
 * Verify signature first (constant-time), then expiry, then shape.
 *
 * @param {string} token
 * @param {object} opts
 * @param {string} opts.secret
 * @param {number} [opts.now]
 * @returns {{ deviceId: string, exp: number } | null} null on any failure
 */
export function verifyToken(token, { secret, now = Date.now() }) {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [payload, signature] = parts;

  const expected = crypto.createHmac("sha256", secret).update(payload, "utf8").digest("base64url");
  if (!constantTimeEqual(signature, expected)) return null;

  let parsed;
  try {
    parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object") return null;
  if (typeof parsed.deviceId !== "string" || parsed.deviceId.length === 0) return null;
  if (typeof parsed.exp !== "number" || !Number.isFinite(parsed.exp)) return null;
  if (now >= parsed.exp) return null;

  return { deviceId: parsed.deviceId, exp: parsed.exp };
}
