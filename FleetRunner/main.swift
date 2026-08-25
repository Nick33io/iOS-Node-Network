import Foundation
import WriteCore
import WriteLAN
import WriteCloud

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// Orchestrates one document across the fleet.
//
// The manager on the iPad observes; this dispatches. It plans on one node,
// fans the sections out across every node that can take one, verifies each
// result locally, and reports what each device actually contributed.
//
// Runs on the M5 Max today. The logic is plain HTTP against /health and
// /generate, so it can move to the Fold later without the nodes changing —
// which is the point of having one contract.

struct Node: Sendable {
  var charactersPerSecond: Double = 0
  let label: String
  let host: String
  var hardware = ""
  var model = ""
  var backend = ""
  var suitedToLongWork = true
  var maxInputCharacters = 3072
  var maxOutputTokens = 512
  var wordBudget = 340
  var reachable = false
  /// Permanent nodes serve unattended; burst nodes only while foregrounded.
  var tier = "burst"
  var takesDependedUponWork = false
  /// Identifies the machine behind the address. Two roster entries can resolve
  /// to the same host — a stale address, a routing quirk, an alias — and
  /// dispatching to both would double-book one device while reporting it as
  /// two. The fingerprint is the only thing that distinguishes them.
  var fingerprint = ""
}

let roster: [(String, String)] = [
  ("M5 Max", "100.73.112.15"),
  ("Mini M4 Pro", "100.101.220.18"),
  ("M3 Air", "100.67.145.126"),
  ("iPhone 15 Pro Max", "100.126.56.73"),
  ("iPhone 17 Pro Max", "100.65.9.108"),
  ("iPad Pro 13", "100.80.12.78"),
  ("iPhone Air", "100.86.4.127"),
  ("Fold 8 Ultra", "100.103.128.56"),
]

func post(_ url: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
  var request = URLRequest(url: URL(string: url)!)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "content-type")
  request.timeoutInterval = timeout
  request.httpBody = try JSONSerialization.data(withJSONObject: body)
  let (data, response) = try await URLSession.shared.data(for: request)
  guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
    let text = String(data: data, encoding: .utf8) ?? ""
    throw RunnerError.http(text.prefix(120).description)
  }
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

enum RunnerError: Error, CustomStringConvertible {
  case http(String)
  case noNodes
  var description: String {
    switch self {
    case .http(let detail): return "node returned: \(detail)"
    case .noNodes: return "no reachable nodes"
    }
  }
}

/// Probe every node at once. Sequential probing lets a single asleep phone
/// delay the whole sweep by its full timeout, and an asleep phone is the
/// normal case for this fleet rather than the exception.
func survey() async -> [Node] {
  await withTaskGroup(of: Node.self) { group in
    for (label, host) in roster {
      group.addTask {
        var node = Node(label: label, host: host)
        var request = URLRequest(url: URL(string: "http://\(host):8833/health")!)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let capabilities = payload["capabilities"] as? [String: Any]
        else { return node }
        node.reachable = true
        node.fingerprint = (payload["profile"] as? [String: Any])?["fingerprint"] as? String ?? ""
        node.hardware = capabilities["hardware"] as? String ?? ""
        node.model = capabilities["model"] as? String ?? ""
        node.backend = capabilities["backend"] as? String ?? ""
        node.suitedToLongWork = capabilities["suitedToLongWork"] as? Bool ?? true
        node.tier = capabilities["tier"] as? String ?? "burst"
        node.takesDependedUponWork = capabilities["takesDependedUponWork"] as? Bool ?? false
        node.maxInputCharacters = capabilities["maxInputCharacters"] as? Int ?? 3072
        node.maxOutputTokens = capabilities["maxOutputTokens"] as? Int ?? 512
        node.wordBudget = capabilities["wordBudgetPerSection"] as? Int ?? 340
        // Measure rather than rank by name. A node's speed decides what it is
        // handed, and hardware identifiers are a poor proxy: the M3 Air and the
        // Mac mini are both 24 GB Macs and differ by more than 2x.
        let probeStart = Date()
        if let body = try? await post(
          "http://\(host):8833/generate",
          ["prompt": "Write one short sentence about scheduling.", "maxOutputTokens": 48],
          timeout: 90
        ) {
          let seconds = max(-probeStart.timeIntervalSinceNow, 0.001)
          let characters = body["characters"] as? Int ?? 0
          // Characters, not the node's own tokensPerSecond: that field is
          // derived from characters/4 against a measured 5.4 chars per token,
          // so it reads about a third high on every device.
          node.charactersPerSecond = Double(characters) / seconds
        }
        return node
      }
    }
    var found: [Node] = []
    for await node in group { found.append(node) }
    return found.sorted { $0.label < $1.label }
  }
}

// MARK: Run

let facts = try FactMap([
  Fact(id: "ORG_1", kind: .org, value: "Ironline Pictures", label: "the production company"),
  Fact(id: "NAME_1", kind: .name, value: "Marisol Vane", label: "the line producer"),
  Fact(id: "NAME_2", kind: .name, value: "Teddy Okafor", label: "the transportation captain"),
  Fact(id: "MONEY_1", kind: .money, value: "$48,500", label: "the transport overage to date"),
  Fact(id: "MONEY_2", kind: .money, value: "$1,900,000", label: "the remaining contingency"),
  Fact(id: "NUMBER_1", kind: .number, value: "11", label: "shooting days remaining"),
  Fact(id: "LOCATION_1", kind: .location, value: "Fairhope, Alabama", label: "the current location"),
])

let brief = """
  Write an internal memo from Marisol Vane to the studio about the transport \
  overage on the Fairhope, Alabama shoot. Ironline Pictures is 11 shooting days \
  from wrap. Transport is $48,500 over, driven by picture-car towing and a \
  second fuel truck Teddy Okafor added during the storm week. Remaining \
  contingency is $1,900,000. Explain the drivers, state why no further overage \
  is expected, and recommend absorbing it from contingency.
  """

print("NOD3 fleet runner\n")
print("surveying...")
let nodes = await survey()

// Keep one entry per physical machine. Without this the fleet looks larger
// than it is, one device silently takes two sections, and the speedup number
// is measuring a queue rather than parallelism.
var seenFingerprints = Set<String>()
var aliases: [String] = []
var workers: [Node] = []
for node in nodes where node.reachable {
  if !node.fingerprint.isEmpty, !seenFingerprints.insert(node.fingerprint).inserted {
    aliases.append(node.label)
    continue
  }
  workers.append(node)
}
for node in nodes {
  let detail =
    node.reachable
    ? "[\(node.tier)] \(node.hardware) · \(node.model)\(node.suitedToLongWork ? "" : " · short leases")"
    : "—"
  print("  " + node.label.padded(20) + node.host.padded(18) + detail)
}
guard !workers.isEmpty else {
  print("\nno reachable nodes")
  exit(1)
}
if !aliases.isEmpty {
  print("\n  ignoring \(aliases.joined(separator: ", ")) — same machine as another entry")
}
let permanent = workers.filter { $0.tier == "permanent" }
let burst = workers.filter { $0.tier != "permanent" }
print("\n\(permanent.count) permanent, \(burst.count) burst\n")

// Plan on the fleet's own planner. The brief is sealed first: the planner sees
// placeholders and labels, never a real name or figure.
let targetWords = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 2400
let abstractor = Abstractor(facts: facts)
let sealedBrief = try abstractor.sealed(brief)
print("planning (brief sealed — \(facts.facts.count) values withheld)...")

// The most constrained node sets the budget: a section sized for a Mac would
// fail the prompt-budget check on a phone, and any node may be handed any
// section.
let floor = workers.map(\.wordBudget).min() ?? 340
// The executive tier. Qwen3-30B-A3B activates ~3B of 30B parameters per token,
// which on the M5 Max returns 373.9 tok/s at concurrency 16 against dense 8B's
// 317 — faster than the smaller dense model and far more capable. It loses to
// dense 4B everywhere, and that is the trade: the fleet's one structural
// decision is worth paying parameters for, the prose is not.
let planner = MLXServerPlanner(
  model: "mlx-community/Qwen3-30B-A3B-4bit",
  baseURL: URL(string: "http://127.0.0.1:8082")!
)
let plannedAt = Date()
let plan = try await planner.plan(
  PlanRequest(
    brief: sealedBrief, catalog: facts.catalog,
    // Sized from the argument so the job can be made big enough to fill the
    // fleet. At the old fixed 600 against a ~340-word floor the planner
    // returned two sections, so a six-node fleet ran on two nodes and the
    // scheduler was right to leave the rest idle — the document, not the
    // dispatch, was the limit.
    wordBudgetPerSection: floor, targetWords: targetWords
  )
).normalized()
let limits = DeviceLimits(
  maxContextTokens: 4096, maxInputCharacters: workers.map(\.maxInputCharacters).min() ?? 3072,
  maxInputTokens: 3072, maxOutputTokens: workers.map(\.maxOutputTokens).min() ?? 512,
  contextHeadroomTokens: 512
)
try plan.validate(against: facts, limits: limits)
print("  \(plan.sections.count) sections in \(String(format: "%.1f", -plannedAt.timeIntervalSinceNow))s: \(plan.title)\n")

// Fan out. Round-robin over available nodes; sections carry no dependencies on
// each other, which is exactly what the cleared KV cache buys.
let builder = SectionPromptBuilder(limits: limits)
let verifier = Verifier(facts: facts)

struct Outcome: Sendable {
  let index: Int
  let section: String
  let node: String
  let seconds: Double
  let tps: Double
  let characters: Int
  let issues: [String]
  let text: String
}

/// Sections waiting to be written, handed out on demand.
///
/// This replaces round-robin-by-section, which gave every node exactly one
/// section and so reproduced the one-request-at-a-time dispatch that hid two
/// thirds of this fleet's throughput: the Macs batch decode, and a Mac holding
/// a single section runs at its slowest possible rate. A queue also removes the
/// need to rank anything — a node that finishes sooner simply pulls again, so
/// capability balances itself.
actor SectionQueue {
  private var pending: [(Int, SectionSpec)]
  init(_ specs: [SectionSpec]) { pending = Array(specs.enumerated()) }
  func next() -> (Int, SectionSpec)? { pending.isEmpty ? nil : pending.removeFirst() }
}

/// How many sections a node may hold at once.
///
/// Macs take a window; phones take exactly one. Concurrency on an iOS node is
/// measurably negative — MLX Swift serialises generation on an actor, so a
/// second in-flight request there costs throughput instead of adding it
/// (iPhone Air: 31.6 tok/s at one stream, 15.9 at four).
func window(for node: Node) -> Int {
  node.hardware.hasPrefix("Mac") ? 4 : 1
}

// Deal, do not race. A pull queue self-balances only when tasks outnumber
// workers; with four sections and eleven workers it is a scramble, and the
// first workers scheduled take everything regardless of how slow their node
// is. The first run of this did exactly that — every section landed on the
// slowest Mac while the fastest sat idle. Dealing strongest-first over a
// capability-sorted roster guarantees the spread, and because the deal wraps
// around, the fastest nodes still collect the remainders.
let ranked = workers.sorted { $0.charactersPerSecond > $1.charactersPerSecond }
print("dispatch order (measured):")
for node in ranked {
  print("  " + node.label.padded(20) + String(format: "%.0f ch/s", node.charactersPerSecond))
}
print("")
// Greedy list scheduling: each section goes to whichever node would finish it
// soonest, given what that node is already holding. Round-robin over a ranked
// list is not enough — with five sections over six nodes it hands one to the
// slowest device, and the slowest device then sets the wall while the fastest
// sits idle after three seconds. Weighting by measured speed lets the M5 Max
// take two sections instead, and drops a node entirely when including it would
// make the document later rather than sooner.
var freeAt: [String: Double] = [:]
var dealt: [String: [(Int, SectionSpec)]] = [:]
for (index, spec) in plan.sections.enumerated() {
  // ~6 characters per word, and never divide by a speed of zero: a node that
  // failed its probe is treated as very slow rather than infinitely fast.
  let characters = Double(spec.targetWords) * 6
  var best: (node: Node, finish: Double)?
  for node in ranked {
    let rate = max(node.charactersPerSecond, 1)
    let finish = (freeAt[node.label] ?? 0) + characters / rate
    if best == nil || finish < best!.finish { best = (node, finish) }
  }
  guard let winner = best else { continue }
  freeAt[winner.node.label] = winner.finish
  dealt[winner.node.label, default: []].append((index, spec))
}
for node in ranked where !(dealt[node.label] ?? []).isEmpty {
  let count = dealt[node.label]!.count
  print("  " + node.label.padded(20) + "\(count) section\(count == 1 ? "" : "s")"
    + String(format: "  (~%.0fs)", freeAt[node.label] ?? 0))
}
print("")

let started = Date()
let outcomes = await withTaskGroup(of: [Outcome].self) { group -> [Outcome] in
  for node in ranked {
    let assignment = dealt[node.label] ?? []
    if assignment.isEmpty { continue }
    group.addTask {
      var mine: [Outcome] = []
      for (index, spec) in assignment {
          // Rehydrated on this machine, never in the cloud: real values enter at
          // the last possible moment.
          let local = SectionSpec(
            id: spec.id, heading: abstractor.rehydrate(spec.heading),
            intent: abstractor.rehydrate(spec.intent),
            points: spec.points.map(abstractor.rehydrate),
            mustInclude: spec.mustInclude, targetWords: min(spec.targetWords, node.wordBudget)
          )
          let required = spec.mustInclude.compactMap { facts[$0]?.value }
          guard let prompt = try? builder.prompt(for: local, previousTail: nil, required: required)
          else { continue }
          do {
            let body = try await post(
              "http://\(node.host):8833/generate",
              ["prompt": prompt, "maxOutputTokens": node.maxOutputTokens], timeout: 300
            )
            let text = (body["text"] as? String ?? "")
              .trimmingCharacters(in: .whitespacesAndNewlines)
            mine.append(Outcome(
              index: index, section: local.heading, node: node.label,
              seconds: body["seconds"] as? Double ?? 0,
              tps: body["tokensPerSecond"] as? Double ?? 0,
              characters: body["characters"] as? Int ?? 0,
              issues: verifier.verify(text, against: local).map(\.description),
              text: text
            ))
          } catch {
            mine.append(Outcome(
              index: index, section: local.heading, node: node.label, seconds: 0, tps: 0,
              characters: 0, issues: ["dispatch failed: \(error)"], text: ""
            ))
          }
        }
      return mine
    }
  }
  var collected: [Outcome] = []
  for await batch in group { collected.append(contentsOf: batch) }
  return collected
}
let wall = -started.timeIntervalSinceNow

print("PER-DEVICE\n")
print("  " + "SECTION".padded(24) + "NODE".padded(20) + "TIME".padded(9)
  + "TOK/S".padded(9) + "CHARS".padded(8) + "VERIFY")
for outcome in outcomes.sorted(by: { $0.seconds > $1.seconds }) {
  let verdict = outcome.issues.isEmpty ? "clean" : "\(outcome.issues.count) issue"
  print(
    "  " + String(outcome.section.prefix(23)).padded(24) + outcome.node.padded(20)
      + String(format: "%.1fs", outcome.seconds).padded(9)
      + String(format: "%.1f", outcome.tps).padded(9)
      + String(outcome.characters).padded(8) + verdict)
}

let sequential = outcomes.reduce(0) { $0 + $1.seconds }
let written = outcomes.reduce(0) { $0 + $1.characters }
print("\n  concurrent wall  \(String(format: "%.1f", wall))s")
print("  sum of parts     \(String(format: "%.1f", sequential))s")
print("  speedup          \(String(format: "%.2f", sequential / max(wall, 0.001)))x")
print("  written          \(written) characters across \(outcomes.count) sections")
let clean = outcomes.filter(\.issues.isEmpty).count
print("  verified         \(clean)/\(outcomes.count) sections clean")

// Assemble here. The fleet wrote the parts; the document only exists on this
// machine, which is also the only machine that ever saw the real values.
let document = ([ "# \(abstractor.rehydrate(plan.title))", "" ]
  + outcomes.sorted { $0.index < $1.index }.flatMap { ["## \($0.section)", "", $0.text, ""] })
  .joined(separator: "\n")
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  .appendingPathComponent("fleet-document.md")
try? document.write(to: out, atomically: true, encoding: .utf8)
let nodesUsed = Set(outcomes.map(\.node)).count
print("  assembled        \(document.count) characters from \(nodesUsed) nodes")
print("  delivered        \(out.path)")

extension String {
  /// Pads to a fixed column width.
  ///
  /// Not `String(format: "%-20s", ...)`: that takes a C string, and bridging a
  /// Swift `String` to get one yields a pointer into a temporary that is freed
  /// before the format call reads it. It segfaults, intermittently, which is
  /// the worst way for it to fail.
  func padded(_ width: Int) -> String {
    count >= width ? self : self + String(repeating: " ", count: width - count)
  }
}
