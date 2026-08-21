# 33write

Plan in the cloud. Write on the device. Verify locally.

A frontier model reasons over **abstracted** input and returns a structured
plan. A 4B model on the phone expands that plan into prose, using real values
that never left the device. A deterministic verifier checks the result.

## Why this shape

A 4B model at 4-bit is poor at deciding *what to say* and adequate at *saying
it*. Splitting on that line lets the small model do the part it can do, and
moves roughly 90% of billable output tokens off the cloud bill.

The privacy argument is the load-bearing one. Writing prose locally protects
nothing if the cloud already saw the names and figures — so the split is
inverted: the cloud reasons over placeholders and neutral labels, and the
device substitutes real values afterwards.

```
brief ──redact──▶ gate ──▶ cloud planner ──▶ plan (placeholders)
                   │                              │
              blocks on leak                   validate
                                                  │
                                             rehydrate (device)
                                                  │
                              ┌──────────── section loop ────────────┐
                              │  prompt → generate → verify → retry  │
                              └──────────────────────────────────────┘
                                                  │
                                              document
```

## Targets

| Target | Role | Network | Sees real values |
|---|---|---|---|
| `WriteCore` | Abstraction, planning types, prompt budgeting, verification, orchestration | no | yes |
| `WriteCloud` | Anthropic Messages API planner | **yes** | **no** |
| `WriteSmoke` | Check harness that runs without Xcode | no | test data only |
| `NodeKit` | Being a node: listener, request boundary, fleet profile, device profile | **yes** | yes |
| `NodeAgent` | A Mac as a node. macOS executable | **yes** | yes |

`WriteCloud` is the only target that reaches *out* to a socket, and it has no
way to reach a `FactMap`. That separation is the whole design. `NodeKit` listens
rather than dials, and never leaves the tailnet.

`NodeKit` and `NodeAgent` are Apple-only — the sources are guarded, so both
compile to nothing on Linux and the portable core keeps one manifest.

## Nodes

Every node — phone, iPad, Mac — answers the same two routes on port 8833 and
publishes the same `33-shell-bridge-fleet/v1` profile:

```
GET  /health    -> identity, memory, thermal, model, backend, enforced limits
POST /generate  -> {prompt, maxOutputTokens?} -> text plus timings
```

A Mac used to be modelled as an Ollama endpoint the phones dialled: outside the
fleet, exempt from the device boundary, invisible to scheduling. It now runs the
same listener behind the same `DeviceLimits`, and Ollama becomes an
implementation detail of one node rather than a second kind of fleet member.

```bash
swift run NodeAgent --backend lan --model llama-33fast:latest
```

The limits are the load-bearing part. Ollama will accept a prompt twice the size
a phone refuses; `/generate` rejects it with `413` **before** a writer is built,
so a section that succeeds on a Mac is one that could have succeeded on a phone.

## The egress boundary

`Abstractor.sealed(_:)` is the only sanctioned way to build a payload for the
cloud. It redacts, then gates — and the gate, not the redactor, is what
guarantees the property:

- **Boundary-aware matching.** A fact valued `12` must not rewrite `2012`, and
  `Acme` must not corrupt `Acmeworks`. Redaction and the gate use the same rule
  so the two cannot disagree.
- **Longest value first.** `Acme Studios Ltd` is consumed before `Acme`, or the
  shorter match strands ` Studios Ltd` in the outbound text.
- **Numeric normalisation.** `$1,250,000` is caught against a stored `1250000`.
  Only applied at three digits or more; below that it fires on ordinary prose.
- **Fail closed.** A thrown `EgressError` is fatal for that request. Do not
  retry the same text.

Known limitation, by design: a value embedded inside a larger token is not
treated as a leak. A gate stricter than the redactor could never pass anything.

## Device limits

Carried over verbatim from the audited `tauri-plugin-mlx-qwen` boundary in
33io — 4096 context, 3072 input characters/tokens, 512 output tokens, cleared
KV cache before every generation.

These shape the architecture rather than sitting beside it:

- 512 output tokens is ~340 words, so a document **must** be written section by
  section. `Plan.validate` rejects any section that asks for more.
- A cleared KV cache means nothing carries between sections implicitly.
  Continuity is passed explicitly in the prompt, and is the first thing
  dropped when the character budget gets tight.

## Verification

Deterministic, no second model call. A 4B model's characteristic failure is
inventing specifics, and specifics are what string and numeric matching catch
for free:

- required facts present in the rendered text
- no placeholder survived rehydration
- no three-plus-digit figure that appears in neither the facts nor the plan
- length within tolerance (advisory — never triggers a retry)

A failing section is retried with the misses named explicitly. Sections that
never come clean are returned in `WrittenDocument.unresolved` rather than
thrown — the caller decides.

## Build

```bash
swift build && swift run write-smoke
```

`swift test` needs the XCTest framework, which ships only with Xcode. If it
reports `no such module 'XCTest'`, point the toolchain at Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Not built yet

- **`WriteMLX`** — the `DeviceWriter` backed by MLX Swift LM, with the pinned
  revision and exact-file manifest carried over from 33io. Needs the iOS SDK.
- **iOS app target** — SwiftUI shell, `increased-memory-limit` entitlement,
  streaming so a two-minute document does not read as a hang.
- **Token broker.** `AnthropicPlanner` takes an API key directly, which is fine
  for development and wrong for a shipped app: anything in the bundle is
  extractable. Point `baseURL` at a broker that holds the key server-side and
  mints short-lived per-device tokens.
