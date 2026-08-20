import Foundation
import WriteCore
import WriteCloud

// Live end-to-end: real Anthropic planner, local Ollama as the device.
// Requires ANTHROPIC_API_KEY in the environment and an Ollama daemon.

let deviceModel = ProcessInfo.processInfo.environment["WRITE_DEV_MODEL"] ?? "33qwen-local:latest"
let plannerModel = ProcessInfo.processInfo.environment["WRITE_DEV_PLANNER"] ?? "33qwen:latest"

// Prefer the real cloud planner when a key is present; otherwise fall back to
// a strong local model so the loop stays runnable without API credits.
let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
let planner: any CloudPlanner = apiKey.isEmpty
  ? OllamaPlanner(model: plannerModel)
  : AnthropicPlanner(apiKey: apiKey)
let plannerName = apiKey.isEmpty ? "\(plannerModel) (local fallback)" : "claude-opus-5"

// A brief with exactly the kind of material that must never egress.
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
  contingency is $1,900,000. The memo should explain the drivers, state why no \
  further overage is expected, and recommend absorbing it from contingency \
  rather than reforecasting.
  """

let pipeline = WritePipeline(
  planner: planner,
  writer: OllamaWriter(model: deviceModel),
  facts: facts,
  maxAttempts: 2
)

print("planner: \(plannerName)    device: \(deviceModel)\n")

do {
  let started = Date()
  let doc = try await pipeline.run(brief: brief, targetWords: 500) { section in
    let mark = section.isClean ? "clean" : "issues: \(section.issues.map(\.description).joined(separator: " | "))"
    print("  [\(section.id)] \(section.heading) — \(section.attempts) attempt(s), \(mark)")
  }
  print("\n──── document ────\n")
  print(doc.markdown)
  print("──────────────────")
  let words = doc.markdown.split(whereSeparator: \.isWhitespace).count
  print("\n\(doc.sections.count) sections, \(words) words, \(Int(-started.timeIntervalSinceNow))s total")
  if !doc.unresolved.isEmpty {
    print("unresolved sections: \(doc.unresolved.map(\.id).joined(separator: ", "))")
  }
} catch {
  FileHandle.standardError.write(Data("pipeline failed: \(error)\n".utf8))
  exit(1)
}
