import Foundation
import WriteCore

// A dependency-free check harness. The XCTest suite in Tests/ is the real
// suite; this exists so the invariants that matter can still be run on a
// toolchain without Xcode, and so CI has something to call.

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
  if condition() {
    print("  ok   \(name)")
  } else {
    print("  FAIL \(name)")
    failures += 1
  }
}

func checkThrows<T>(_ name: String, _ body: () throws -> T) {
  do {
    _ = try body()
    print("  FAIL \(name) — expected a throw")
    failures += 1
  } catch {
    print("  ok   \(name) — \(error)")
  }
}

let facts = try FactMap([
  Fact(id: "ORG_1", kind: .org, value: "Acme Studios Ltd", label: "the production company"),
  Fact(id: "ORG_2", kind: .org, value: "Acme", label: "the parent group"),
  Fact(id: "NAME_1", kind: .name, value: "Dana Reyes", label: "the line producer"),
  Fact(id: "MONEY_1", kind: .money, value: "$1,250,000", label: "the department allocation"),
])
let abstractor = Abstractor(facts: facts)

print("egress boundary")
check("longest value wins", abstractor.redact("Acme Studios Ltd owns it") == "[[ORG_1]] owns it")
check("case-insensitive, canonical output",
      abstractor.redact("dana reyes and DANA REYES") == "[[NAME_1]] and [[NAME_1]]")
let sealedBrief = try abstractor.sealed("Dana Reyes at Acme Studios Ltd spent $1,250,000.")
check("sealed brief carries no values", !sealedBrief.contains("Dana"))
checkThrows("plain value is blocked") { try abstractor.assertNoLeak("Dana Reyes signed off") }
checkThrows("reformatted figure is blocked") { try abstractor.assertNoLeak("spent 1250000 total") }
let shortFacts = try FactMap([Fact(id: "NUMBER_1", kind: .number, value: "12", label: "episodes")])
let shortAbstractor = Abstractor(facts: shortFacts)
check("short value does not redact inside a longer number",
      shortAbstractor.redact("shot in 2012 over 12 days") == "shot in 2012 over [[NUMBER_1]] days")
check("value does not redact inside a longer word",
      abstractor.redact("Acmeworks is not Acme") == "Acmeworks is not [[ORG_2]]")
check("sealed passes once short values are redacted",
      (try? shortAbstractor.sealed("shot in 2012 over 12 days")) != nil)

check("rehydrate restores values",
      abstractor.rehydrate("[[NAME_1]] at [[ORG_1]]") == "Dana Reyes at Acme Studios Ltd")

let encodedCatalog = String(data: try JSONEncoder().encode(facts.catalog), encoding: .utf8)!
check("catalog carries labels, not values",
      !encodedCatalog.contains("Dana Reyes") && encodedCatalog.contains("the line producer"))

print("plan validation")
let limits = DeviceLimits.qwen3_4B_4bit
func plan(_ sections: [SectionSpec]) -> Plan {
  Plan(title: "Memo", audience: "producers", tone: "plain", sections: sections)
}
func spec(id: String = "s1", intent: String = "Report.", must: [String] = [], words: Int = 80) -> SectionSpec {
  SectionSpec(id: id, heading: "Status", intent: intent, points: [], mustInclude: must, targetWords: words)
}
check("bracketed mustInclude normalises to the bare id",
      plan([spec(must: ["[[NAME_1]]"], words: 80)]).normalized()
        .sections[0].mustInclude == ["NAME_1"])
check("well-formed plan validates",
      (try? plan([spec(intent: "Report on [[NAME_1]].", must: ["NAME_1"])])
        .validate(against: facts, limits: limits)) != nil)
checkThrows("hallucinated placeholder rejected") {
  try plan([spec(intent: "Report on [[NAME_9]].")]).validate(against: facts, limits: limits)
}
checkThrows("oversized section rejected") {
  try plan([spec(words: 900)]).validate(against: facts, limits: limits)
}
checkThrows("duplicate section id rejected") {
  try plan([spec(id: "s1"), spec(id: "s1")]).validate(against: facts, limits: limits)
}
checkThrows("unknown required fact rejected") {
  try plan([spec(must: ["MONEY_4"])]).validate(against: facts, limits: limits)
}

print("verifier")
let verifier = Verifier(facts: facts)
let vSpec = SectionSpec(id: "s1", heading: "Status", intent: "Summarise.",
                        points: ["Cover the 42-day schedule."], mustInclude: ["NAME_1"], targetWords: 100)
check("clean section passes", verifier.verify("Dana Reyes closed the week.", against: vSpec).isEmpty)
check("missing required fact caught",
      verifier.verify("The producer closed it.", against: vSpec)
        == [.missingFact(id: "NAME_1", value: "Dana Reyes")])
check("residual placeholder caught",
      verifier.verify("[[NAME_1]] closed it.", against: vSpec)
        .contains(.residualPlaceholder("NAME_1")))
check("invented figure caught",
      verifier.verify("Dana Reyes reported 8,400 units.", against: vSpec)
        == [.unsupportedNumber("8400")])
check("supplied figure accepted",
      verifier.verify("Dana Reyes noted $1,250,000.", against: vSpec).isEmpty)
check("over-length is advisory only",
      verifier.verify("Dana Reyes " + String(repeating: "word ", count: 300), against: vSpec)
        .allSatisfy { !$0.warrantsRetry })

print("prompt budget")
let builder = SectionPromptBuilder(limits: limits)
let long = try builder.prompt(for: vSpec, previousTail: String(repeating: "tail ", count: 400))
check("prompt fits the character cap", long.count <= limits.maxInputCharacters)
check("continuity is carried when it fits", long.contains("THE PRECEDING SECTION ENDED"))
checkThrows("unfittable section is rejected") {
  try builder.prompt(for: SectionSpec(id: "s1", heading: "H",
                                      intent: String(repeating: "x", count: 4000),
                                      points: [], mustInclude: [], targetWords: 80),
                     previousTail: nil)
}

print("pipeline")
struct StubPlanner: CloudPlanner {
  let result: Plan
  let box: LockedBox<PlanRequest?>
  func plan(_ request: PlanRequest) async throws -> Plan { box.set(request); return result }
}
final class ScriptedWriter: DeviceWriter, @unchecked Sendable {
  let limits = DeviceLimits.qwen3_4B_4bit
  private var responses: [String]
  private(set) var prompts: [String] = []
  init(_ r: [String]) { responses = r }
  func generate(prompt: String, maxOutputTokens: Int) async throws -> String {
    prompts.append(prompt)
    return responses.isEmpty ? "" : responses.removeFirst()
  }
}
final class LockedBox<T>: @unchecked Sendable {
  private var value: T; private let lock = NSLock()
  init(_ v: T) { value = v }
  func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
  func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

let livePlan = Plan(
  title: "Week 6 for [[NAME_1]]", audience: "producers", tone: "plain",
  sections: [
    SectionSpec(id: "s1", heading: "Status", intent: "Report on [[NAME_1]].",
                points: [], mustInclude: ["NAME_1"], targetWords: 80),
    SectionSpec(id: "s2", heading: "Budget", intent: "Explain [[MONEY_1]].",
                points: [], mustInclude: ["MONEY_1"], targetWords: 80),
  ]
)

let box = LockedBox<PlanRequest?>(nil)
let writer = ScriptedWriter(["Dana Reyes held steady.", "It stands at $1,250,000."])
let doc = try await WritePipeline(
  planner: StubPlanner(result: livePlan, box: box), writer: writer, facts: facts
).run(brief: "How did Dana Reyes do against $1,250,000?")

check("document is rehydrated", doc.title == "Week 6 for Dana Reyes")
check("all sections clean", doc.unresolved.isEmpty)
check("markdown assembles", doc.markdown.contains("## Status") && doc.markdown.contains("$1,250,000"))
let sent = box.get()!
check("brief reached planner redacted",
      !sent.brief.contains("Dana Reyes") && sent.brief.contains("[[NAME_1]]"))
check("second section carried continuity",
      writer.prompts[1].contains("Dana Reyes held steady."))
check("required values are in the prompt from attempt one",
      writer.prompts[0].contains("MUST APPEAR VERBATIM") &&
      writer.prompts[0].contains("Dana Reyes"))

let retryWriter = ScriptedWriter(["The producer held steady.", "Dana Reyes held steady.",
                                  "It stands at $1,250,000."])
let retried = try await WritePipeline(
  planner: StubPlanner(result: livePlan, box: LockedBox(nil)),
  writer: retryWriter, facts: facts, maxAttempts: 2
).run(brief: "Summarise the week.")
check("missing fact triggered a retry", retried.sections[0].attempts == 2)
check("retry named the missing value", retryWriter.prompts[1].contains("state exactly: Dana Reyes"))
check("retry recovered", retried.sections[0].isClean)

let blockedBox = LockedBox<PlanRequest?>(nil)
do {
  _ = try await WritePipeline(
    planner: StubPlanner(result: livePlan, box: blockedBox),
    writer: ScriptedWriter([]),
    facts: try FactMap([Fact(id: "MONEY_1", kind: .money, value: "$1,250,000", label: "allocation")])
  ).run(brief: "The team spent 1250000 this week.")
  check("unredactable brief blocked", false)
} catch {
  check("unredactable brief blocked", true)
}
check("planner never reached when the gate trips", blockedBox.get() == nil)

print("")
if failures == 0 {
  print("all checks passed")
} else {
  print("\(failures) check(s) failed")
  exit(1)
}
