import assert from "node:assert/strict";
import http from "node:http";
import { after, before, beforeEach, test } from "node:test";

import { loadConfig } from "../src/config.js";
import { createBroker } from "../src/server.js";
import { signToken, verifyToken } from "../src/token.js";

const SIGNING_SECRET = "test-signing-secret";
const ENROLL_KEY = "test-enroll-key";
const API_KEY = "sk-ant-test-not-real";

// ---------------------------------------------------------------------------
// Token unit tests
// ---------------------------------------------------------------------------

test("token round-trip: signed token verifies to the same deviceId", () => {
  const { token, expiresAt } = signToken({
    deviceId: "device-1",
    secret: SIGNING_SECRET,
    ttlMs: 15 * 60 * 1000,
    now: 1_000_000,
  });
  assert.equal(expiresAt, 1_000_000 + 15 * 60 * 1000);
  const claims = verifyToken(token, { secret: SIGNING_SECRET, now: 1_000_001 });
  assert.ok(claims, "token should verify");
  assert.equal(claims.deviceId, "device-1");
  assert.equal(claims.exp, expiresAt);
});

test("expired token is rejected", () => {
  const { token } = signToken({
    deviceId: "device-1",
    secret: SIGNING_SECRET,
    ttlMs: 15 * 60 * 1000,
    now: 1_000_000,
  });
  const claims = verifyToken(token, {
    secret: SIGNING_SECRET,
    now: 1_000_000 + 15 * 60 * 1000, // exactly at expiry: already invalid
  });
  assert.equal(claims, null);
});

test("tampered token is rejected", () => {
  const { token } = signToken({
    deviceId: "device-1",
    secret: SIGNING_SECRET,
    ttlMs: 15 * 60 * 1000,
  });
  const [payload, signature] = token.split(".");

  // Swap the payload for one claiming a different device, keep the signature.
  const forgedPayload = Buffer.from(
    JSON.stringify({ deviceId: "device-2", exp: Date.now() + 10_000 }),
    "utf8",
  ).toString("base64url");
  assert.equal(verifyToken(`${forgedPayload}.${signature}`, { secret: SIGNING_SECRET }), null);

  // Flip a character in the signature.
  const flipped = signature[0] === "A" ? "B" : "A";
  assert.equal(
    verifyToken(`${payload}.${flipped}${signature.slice(1)}`, { secret: SIGNING_SECRET }),
    null,
  );

  // Token signed with a different secret.
  const { token: foreign } = signToken({
    deviceId: "device-1",
    secret: "some-other-secret",
    ttlMs: 60_000,
  });
  assert.equal(verifyToken(foreign, { secret: SIGNING_SECRET }), null);
});

// ---------------------------------------------------------------------------
// Config fail-closed
// ---------------------------------------------------------------------------

test("loadConfig fails closed when a required variable is missing", () => {
  assert.throws(
    () => loadConfig({ BROKER_ENROLL_KEY: "x", BROKER_SIGNING_SECRET: "y" }),
    /ANTHROPIC_API_KEY/,
  );
});

// ---------------------------------------------------------------------------
// HTTP tests against a live broker with a mock upstream
// ---------------------------------------------------------------------------

/** What the mock upstream saw for the most recent request. */
let upstreamSeen;
let upstream;
let broker;
let brokerUrl;

before(async () => {
  upstream = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      upstreamSeen = {
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      };
      res.writeHead(200, { "content-type": "application/json", "request-id": "req_mock_1" });
      res.end(JSON.stringify({ id: "msg_mock", content: [{ type: "text", text: "{}" }] }));
    });
  });
  await new Promise((r) => upstream.listen(0, "127.0.0.1", r));

  const config = loadConfig({
    BROKER_ENROLL_KEY: ENROLL_KEY,
    BROKER_SIGNING_SECRET: SIGNING_SECRET,
    ANTHROPIC_API_KEY: API_KEY,
    BROKER_MODEL_ALLOWLIST: "claude-opus-5, claude-haiku-4-5",
    BROKER_UPSTREAM_URL: `http://127.0.0.1:${upstream.address().port}`,
  });
  broker = createBroker(config, { log: () => {} });
  await new Promise((r) => broker.listen(0, "127.0.0.1", r));
  brokerUrl = `http://127.0.0.1:${broker.address().port}`;
});

after(async () => {
  await new Promise((r) => broker.close(r));
  await new Promise((r) => upstream.close(r));
});

beforeEach(() => {
  upstreamSeen = undefined;
});

async function enroll(deviceId, key = ENROLL_KEY) {
  return fetch(`${brokerUrl}/v1/enroll`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-enroll-key": key },
    body: JSON.stringify({ deviceId }),
  });
}

async function plan(token, body) {
  return fetch(`${brokerUrl}/v1/plan`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("healthz responds 200 without auth", async () => {
  const res = await fetch(`${brokerUrl}/healthz`);
  assert.equal(res.status, 200);
});

test("enroll with missing or wrong key is rejected, correct key mints a token", async () => {
  const missing = await fetch(`${brokerUrl}/v1/enroll`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ deviceId: "d" }),
  });
  assert.equal(missing.status, 401);

  const wrong = await enroll("d", "not-the-enrollment-key");
  assert.equal(wrong.status, 401);

  const ok = await enroll("device-http");
  assert.equal(ok.status, 200);
  const { token, expiresAt } = await ok.json();
  assert.ok(typeof token === "string" && token.includes("."));
  assert.ok(expiresAt > Date.now());
  assert.ok(expiresAt <= Date.now() + 15 * 60 * 1000 + 1000, "TTL is 15 minutes");
});

test("plan forwards verbatim to the upstream with server-held key and returns its response", async () => {
  const { token } = await (await enroll("device-forward")).json();
  const body = { model: "claude-opus-5", max_tokens: 16, messages: [{ role: "user", content: "hi" }] };
  const res = await plan(token, body);

  assert.equal(res.status, 200);
  assert.equal(res.headers.get("request-id"), "req_mock_1");
  const echoed = await res.json();
  assert.equal(echoed.id, "msg_mock");

  assert.equal(upstreamSeen.method, "POST");
  assert.equal(upstreamSeen.url, "/v1/messages");
  assert.equal(upstreamSeen.headers["x-api-key"], API_KEY);
  assert.equal(upstreamSeen.headers["anthropic-version"], "2023-06-01");
  assert.equal(upstreamSeen.headers["anthropic-beta"], "server-side-fallback-2026-07-01");
  assert.equal(upstreamSeen.body, JSON.stringify(body), "raw body forwarded byte-for-byte");
});

test("plan without a token, with a tampered token, and with an expired token is rejected", async () => {
  const noAuth = await fetch(`${brokerUrl}/v1/plan`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "claude-opus-5" }),
  });
  assert.equal(noAuth.status, 401);

  const { token } = await (await enroll("device-auth")).json();
  const tampered = await plan(`${token}x`, { model: "claude-opus-5" });
  assert.equal(tampered.status, 401);

  const { token: expired } = signToken({
    deviceId: "device-auth",
    secret: SIGNING_SECRET,
    ttlMs: 1000,
    now: Date.now() - 10_000,
  });
  const late = await plan(expired, { model: "claude-opus-5" });
  assert.equal(late.status, 401);

  assert.equal(upstreamSeen, undefined, "nothing reached the upstream");
});

test("oversized body is rejected with 413 and never forwarded", async () => {
  const { token } = await (await enroll("device-big")).json();
  const big = JSON.stringify({ model: "claude-opus-5", pad: "x".repeat(64 * 1024) });
  const res = await plan(token, big);
  assert.equal(res.status, 413);
  assert.equal(upstreamSeen, undefined);
});

test("invalid JSON body is rejected with 400", async () => {
  const { token } = await (await enroll("device-json")).json();
  const res = await plan(token, "{not json");
  assert.equal(res.status, 400);
  assert.equal(upstreamSeen, undefined);
});

test("disallowed model is rejected and never forwarded", async () => {
  const { token } = await (await enroll("device-model")).json();
  const res = await plan(token, { model: "gpt-oss-120b", messages: [] });
  assert.equal(res.status, 403);
  const missing = await plan(token, { messages: [] });
  assert.equal(missing.status, 403);
  assert.equal(upstreamSeen, undefined);
});

test("rate limit trips on the 11th request in a minute, per device", async () => {
  const { token } = await (await enroll("device-rate")).json();
  const body = { model: "claude-opus-5", messages: [] };
  for (let i = 0; i < 10; i++) {
    const res = await plan(token, body);
    assert.equal(res.status, 200, `request ${i + 1} should pass`);
  }
  const eleventh = await plan(token, body);
  assert.equal(eleventh.status, 429);

  // A different device is unaffected: the window is per-device.
  const { token: other } = await (await enroll("device-rate-2")).json();
  const fresh = await plan(other, body);
  assert.equal(fresh.status, 200);
});
