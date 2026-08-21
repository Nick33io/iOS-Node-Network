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
  /// Identifies the machine behind the address. Two roster entries can resolve
  /// to the same host — a stale address, a routing quirk, an alias — and
  /// dispatching to both would double-book one device while reporting it as
  /// two. The fingerprint is the only thing that distinguishes them.
  var fingerprint = ""
}

let roster: [(String, String)] = [
  ("M5 Max", "100.73.112.15"),
  ("Mini M4 Pro", "100.101.220.18"),
  ("iPhone 15 Pro Max", "100.126.56.73"),
  ("iPhone 17 Pro Max", "100.65.9.108"),
  ("iPad Pro 13", "100.80.12.78"),
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
        node.maxInputCharacters = capabilities["maxInputCharacters"] as? Int ?? 3072
        node.maxOutputTokens = capabilities["maxOutputTokens"] as? Int ?? 512
        node.wordBudget = capabilities["wordBudgetPerSection"] as? Int ?? 340
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
    ? "\(node.hardware) · \(node.model)\(node.suitedToLongWork ? "" : " · short leases")" : "—"
  print("  " + node.label.padded(20) + node.host.padded(18) + detail)
}
guard !workers.isEmpty else {
  print("\nno reachable nodes")
  exit(1)
}
if !aliases.isEmpty {
  print("\n  ignoring \(aliases.joined(separator: ", ")) — same machine as another entry")
}
print("\n\(workers.count) distinct node(s) available\n")

// Plan on the fleet's own planner. The brief is sealed first: the planner sees
// placeholders and labels, never a real name or figure.
let abstractor = Abstractor(facts: facts)
let sealedBrief = try abstractor.sealed(brief)
print("planning (brief sealed — \(facts.facts.count) values withheld)...")

// The most constrained node sets the budget: a section sized for a Mac would
// fail the prompt-budget check on a phone, and any node may be handed any
// section.
let floor = workers.map(\.wordBudget).min() ?? 340
let planner = LANPlanner(model: "llama-33fast:latest", baseURL: URL(string: "http://127.0.0.1:11434")!)
let plannedAt = Date()
let plan = try await planner.plan(
  PlanRequest(
    brief: sealedBrief, catalog: facts.catalog,
    wordBudgetPerSection: floor, targetWords: 600
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
  let section: String
  let node: String
  let seconds: Double
  let tps: Double
  let characters: Int
  let issues: [String]
  let text: String
}

let started = Date()
let outcomes = await withTaskGroup(of: Outcome?.self) { group -> [Outcome] in
  for (index, spec) in plan.sections.enumerated() {
    let node = workers[index % workers.count]
    group.addTask {
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
      else { return nil }
      do {
        let body = try await post(
          "http://\(node.host):8833/generate",
          ["prompt": prompt, "maxOutputTokens": node.maxOutputTokens], timeout: 300
        )
        let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(
          section: local.heading, node: node.label,
          seconds: body["seconds"] as? Double ?? 0,
          tps: body["tokensPerSecond"] as? Double ?? 0,
          characters: body["characters"] as? Int ?? 0,
          issues: verifier.verify(text, against: local).map(\.description),
          text: text
        )
      } catch {
        return Outcome(
          section: local.heading, node: node.label, seconds: 0, tps: 0, characters: 0,
          issues: ["dispatch failed: \(error)"], text: ""
        )
      }
    }
  }
  var collected: [Outcome] = []
  for await outcome in group { if let outcome { collected.append(outcome) } }
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
