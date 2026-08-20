/**
 * The broker HTTP server. Three routes, no framework, no dependencies:
 *
 *   POST /v1/enroll  — shared enrollment secret in, short-lived token out
 *   POST /v1/plan    — bearer token in, request forwarded to Anthropic
 *   GET  /healthz    — liveness, no auth
 *
 * Deliberately no CORS headers anywhere: the clients are devices, not
 * browsers, and a browser origin has no business talking to this service.
 */

import http from "node:http";
import https from "node:https";

import { SlidingWindowLimiter } from "./ratelimit.js";
import { constantTimeEqual, signToken, verifyToken } from "./token.js";

const ANTHROPIC_VERSION = "2023-06-01";
const ANTHROPIC_BETA = "server-side-fallback-2026-07-01";
const MAX_DEVICE_ID_LENGTH = 128;

/**
 * Structured request log line. Method, path, device id, status, latency —
 * and nothing else. Request bodies, tokens, and secrets must never pass
 * through here.
 */
function defaultLog(fields) {
  const { method, path, deviceId, status, latencyMs } = fields;
  console.log(
    `${new Date().toISOString()} ${method} ${path} device=${deviceId ?? "-"} status=${status} latency=${latencyMs}ms`,
  );
}

function sendJson(res, status, body) {
  const buf = Buffer.from(JSON.stringify(body), "utf8");
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": buf.length,
  });
  res.end(buf);
}

/**
 * Read a request body up to `limit` bytes. Resolves with the raw Buffer or
 * rejects with { tooLarge: true } the moment the limit is crossed.
 */
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    // Fast path: an honest Content-Length over the limit is refused before
    // reading a single chunk.
    const declared = Number(req.headers["content-length"]);
    if (Number.isFinite(declared) && declared > limit) {
      req.resume(); // drain so the socket can be reused or torn down cleanly
      reject({ tooLarge: true });
      return;
    }
    const chunks = [];
    let size = 0;
    let settled = false;
    req.on("data", (chunk) => {
      if (settled) return;
      size += chunk.length;
      if (size > limit) {
        settled = true;
        reject({ tooLarge: true });
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on("error", (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    });
  });
}

/**
 * Forward the (already validated) raw body to the upstream Messages API and
 * stream the response back byte-for-byte with the upstream status.
 *
 * @returns {Promise<number>} the status sent to the client
 */
function forwardToUpstream(config, bodyBuf, clientRes) {
  return new Promise((resolve) => {
    const url = new URL("/v1/messages", config.upstreamUrl);
    const transport = url.protocol === "https:" ? https : http;
    const upstreamReq = transport.request(
      url,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": bodyBuf.length,
          "x-api-key": config.anthropicApiKey,
          "anthropic-version": ANTHROPIC_VERSION,
          "anthropic-beta": ANTHROPIC_BETA,
        },
      },
      (upstreamRes) => {
        const headers = { ...upstreamRes.headers };
        // Hop-by-hop headers do not survive proxying; everything else
        // (content-type, request ids, rate-limit hints) passes through.
        delete headers.connection;
        delete headers["transfer-encoding"];
        delete headers["keep-alive"];
        clientRes.writeHead(upstreamRes.statusCode, headers);
        upstreamRes.pipe(clientRes);
        upstreamRes.on("end", () => resolve(upstreamRes.statusCode));
        upstreamRes.on("error", () => {
          clientRes.destroy();
          resolve(upstreamRes.statusCode);
        });
      },
    );
    upstreamReq.on("error", () => {
      if (!clientRes.headersSent) {
        sendJson(clientRes, 502, { error: "upstream unreachable" });
      } else {
        clientRes.destroy();
      }
      resolve(502);
    });
    upstreamReq.end(bodyBuf);
  });
}

/**
 * Build (but do not start) the broker server.
 *
 * @param {ReturnType<import('./config.js').loadConfig>} config
 * @param {{ log?: (fields: object) => void }} [hooks]
 */
export function createBroker(config, { log = defaultLog } = {}) {
  const limiter = new SlidingWindowLimiter({
    max: config.rateLimitMax,
    windowMs: config.rateLimitWindowMs,
  });

  const server = http.createServer(async (req, res) => {
    const startedAt = Date.now();
    const path = (req.url || "/").split("?")[0];
    let deviceId; // set once authenticated; only ever logged, never bodies

    const finish = (status) =>
      log({ method: req.method, path, deviceId, status, latencyMs: Date.now() - startedAt });
    res.on("finish", () => finish(res.statusCode));
    res.on("close", () => {
      if (!res.writableFinished) finish(res.statusCode || 0);
    });

    try {
      if (req.method === "GET" && path === "/healthz") {
        sendJson(res, 200, { ok: true });
        return;
      }

      if (req.method === "POST" && path === "/v1/enroll") {
        const presented = req.headers["x-enroll-key"];
        if (typeof presented !== "string" || !constantTimeEqual(presented, config.enrollKey)) {
          sendJson(res, 401, { error: "invalid enrollment key" });
          return;
        }

        let body;
        try {
          body = JSON.parse((await readBody(req, config.maxBodyBytes)).toString("utf8"));
        } catch (err) {
          sendJson(res, err && err.tooLarge ? 413 : 400, { error: "invalid enrollment request" });
          return;
        }
        const requested = body && typeof body === "object" ? body.deviceId : undefined;
        if (
          typeof requested !== "string" ||
          requested.length === 0 ||
          requested.length > MAX_DEVICE_ID_LENGTH
        ) {
          sendJson(res, 400, { error: "deviceId must be a non-empty string" });
          return;
        }

        deviceId = requested;
        const { token, expiresAt } = signToken({
          deviceId,
          secret: config.signingSecret,
          ttlMs: config.tokenTtlMs,
        });
        sendJson(res, 200, { token, expiresAt });
        return;
      }

      if (req.method === "POST" && path === "/v1/plan") {
        const auth = req.headers.authorization || "";
        const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : null;
        const claims = token ? verifyToken(token, { secret: config.signingSecret }) : null;
        if (!claims) {
          sendJson(res, 401, { error: "invalid or expired token" });
          return;
        }
        deviceId = claims.deviceId;

        if (!limiter.allow(deviceId)) {
          sendJson(res, 429, { error: "rate limit exceeded" });
          return;
        }
        limiter.prune();

        let raw;
        try {
          raw = await readBody(req, config.maxBodyBytes);
        } catch (err) {
          sendJson(res, err && err.tooLarge ? 413 : 400, { error: "unreadable request body" });
          return;
        }

        let parsed;
        try {
          parsed = JSON.parse(raw.toString("utf8"));
        } catch {
          sendJson(res, 400, { error: "request body must be valid JSON" });
          return;
        }

        const model = parsed && typeof parsed === "object" ? parsed.model : undefined;
        if (typeof model !== "string" || !config.modelAllowlist.has(model)) {
          sendJson(res, 403, { error: "model not allowed" });
          return;
        }

        // Forward the raw bytes, not a re-serialisation — the upstream sees
        // exactly what the device sent.
        await forwardToUpstream(config, raw, res);
        return;
      }

      sendJson(res, 404, { error: "not found" });
    } catch {
      // Deliberately no error detail in the log or the response: detail can
      // quote body content.
      if (!res.headersSent) {
        sendJson(res, 500, { error: "internal error" });
      } else {
        res.destroy();
      }
    }
  });

  return server;
}
