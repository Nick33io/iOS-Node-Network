# Broker

A token broker that fronts the Anthropic Messages API so a shipped device
never holds the API key. `AnthropicPlanner` in `Sources/WriteCloud` points its
`baseURL` at this service instead of `api.anthropic.com`; the key lives only
here, server-side.

Zero runtime dependencies: Node.js >= 20, `node:http`, `node:crypto`,
`node:test`. There is nothing to `npm install`.

## Running

```sh
export BROKER_ENROLL_KEY="..."      # shared enrollment secret
export BROKER_SIGNING_SECRET="..."  # HMAC key for device tokens
export ANTHROPIC_API_KEY="sk-ant-..."
node broker/src/index.js            # listens on :8484 (override with PORT)
```

Tests (no network, the upstream is a local mock):

```sh
node --test broker/
```

> The package `main` intentionally points at the test suite: `node --test`
> resolves a directory argument through `package.json#main`, and that is what
> makes the exact command above work. The service entry point is
> `src/index.js`, started via `npm start` or directly.

## Environment

| Variable | Required | Meaning |
| --- | --- | --- |
| `BROKER_ENROLL_KEY` | yes | Shared secret a device presents (header `X-Enroll-Key`) to enroll. |
| `BROKER_SIGNING_SECRET` | yes | HMAC-SHA256 key for minting and verifying device tokens. |
| `ANTHROPIC_API_KEY` | yes | The upstream key. Exists only on this server. |
| `BROKER_MODEL_ALLOWLIST` | no | Comma-separated models a device may request. Default `claude-opus-5`. |
| `BROKER_UPSTREAM_URL` | no | Upstream base URL. Default `https://api.anthropic.com`. Tests point it at a mock. |
| `PORT` | no | Listen port. Default `8484`. |

Startup fails closed: if any required variable is missing the process prints
which ones and exits non-zero before opening a socket.

## Endpoints

- `POST /v1/enroll` — body `{"deviceId": "..."}`, header `X-Enroll-Key`.
  Returns `{"token": "...", "expiresAt": <ms epoch>}`. Tokens live 15 minutes.
- `POST /v1/plan` — header `Authorization: Bearer <token>`. The JSON body is
  forwarded verbatim to `POST https://api.anthropic.com/v1/messages` with the
  server-held key and headers `anthropic-version: 2023-06-01`,
  `anthropic-beta: server-side-fallback-2026-07-01`. The upstream status and
  body come back unchanged.
- `GET /healthz` — liveness, no auth.

## Security model

**The key never ships.** Anything compiled into an app bundle is extractable,
so the Anthropic key cannot go to devices. Instead a device proves membership
once (the enrollment secret, provisioned through your distribution channel)
and receives a short-lived token: a base64url payload (`deviceId`, expiry)
signed with HMAC-SHA256 under `BROKER_SIGNING_SECRET`. Verification is
stateless — signature first, then expiry — and the signature check uses
`crypto.timingSafeEqual` over hashed inputs, as does the enrollment-key
comparison, so neither comparison leaks timing. A stolen token is worth at
most 15 minutes of narrowly scoped access; a stolen device binary is worth
nothing.

**The blast radius of a leaked token is capped.** `/v1/plan` only reaches one
upstream route, refuses request bodies that are not valid JSON or exceed 64KB,
refuses any `model` outside the allowlist, and rate-limits each device to 10
requests per sliding minute (in-memory; move to a shared store if you run more
than one instance). A compromised device can burn its own quota on the cheap
allowed models and nothing else.

**The broker cannot leak what it never records.** Logs carry method, path,
device id, status, and latency — never request bodies, never tokens, never
error detail that could quote a body. Note the pipeline's privacy property
does not depend on this: by the time a request reaches the broker it has
already been sealed by `Abstractor` (see the repository README), so the broker
only ever sees placeholders. The logging rule is defense in depth.

**No CORS, ever.** Clients are devices, not browsers. No `Access-Control-*`
headers are emitted, so a browser origin cannot be scripted against this
service.
