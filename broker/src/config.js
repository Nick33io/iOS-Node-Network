/**
 * Startup configuration. Fails closed: a broker missing any secret refuses
 * to start rather than starting in a degraded (and therefore surprising)
 * state.
 */

const REQUIRED = ["BROKER_ENROLL_KEY", "BROKER_SIGNING_SECRET", "ANTHROPIC_API_KEY"];

export const DEFAULT_MODEL_ALLOWLIST = "claude-opus-5";
export const TOKEN_TTL_MS = 15 * 60 * 1000; // 15 minutes
export const MAX_BODY_BYTES = 64 * 1024; // 64KB
export const RATE_LIMIT_MAX = 10; // requests
export const RATE_LIMIT_WINDOW_MS = 60 * 1000; // per sliding minute

/**
 * @param {Record<string, string | undefined>} env
 */
export function loadConfig(env = process.env) {
  const missing = REQUIRED.filter((name) => !env[name]);
  if (missing.length > 0) {
    throw new Error(
      `broker: refusing to start — missing required environment variable(s): ${missing.join(", ")}. ` +
        "Set BROKER_ENROLL_KEY (shared enrollment secret), BROKER_SIGNING_SECRET " +
        "(token HMAC key), and ANTHROPIC_API_KEY (upstream key).",
    );
  }

  const allowlist = (env.BROKER_MODEL_ALLOWLIST || DEFAULT_MODEL_ALLOWLIST)
    .split(",")
    .map((m) => m.trim())
    .filter((m) => m.length > 0);
  if (allowlist.length === 0) {
    throw new Error("broker: refusing to start — BROKER_MODEL_ALLOWLIST is set but empty.");
  }

  return {
    enrollKey: env.BROKER_ENROLL_KEY,
    signingSecret: env.BROKER_SIGNING_SECRET,
    anthropicApiKey: env.ANTHROPIC_API_KEY,
    modelAllowlist: new Set(allowlist),
    // Overridable so tests can point at a local mock. Production leaves this
    // unset and talks to the real API.
    upstreamUrl: env.BROKER_UPSTREAM_URL || "https://api.anthropic.com",
    port: env.PORT ? Number(env.PORT) : 8484,
    tokenTtlMs: TOKEN_TTL_MS,
    maxBodyBytes: MAX_BODY_BYTES,
    rateLimitMax: RATE_LIMIT_MAX,
    rateLimitWindowMs: RATE_LIMIT_WINDOW_MS,
  };
}
