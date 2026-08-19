import XCTest
@testable import WriteCore

private struct StubPlanner: CloudPlanner {
  let plan: Plan
  /// Captures what actually crossed the boundary, so a test can assert on it.
  let seen: @Sendable (PlanRequest) -> Void

  func plan(_ request: PlanRequest) async throws -> Plan {
    seen(request)
    return plan
  }
}

private final class ScriptedWriter: DeviceWriter, @unchecked Sendable {
  let limits = DeviceLimits.qwen3_4B_4bit
  private var responses: [String]
  private(set) var prompts: [String] = []

  init(_ responses: [String]) { self.responses = responses }

  func generate(prompt: String, maxOutputTokens: Int) async throws -> String {
    prompts.append(prompt)
    return responses.isEmpty ? "" : responses.removeFirst()
  }
}

final class PipelineTests: XCTestCase {
  private func facts() throws -> FactMap {
    try FactMap([
      Fact(id: "NAME_1", kind: .name, value: "Dana Reyes", label: "the line producer"),
      Fact(id: "MONEY_1", kind: .money, value: "$1,250,000", label: "the allocation"),
    ])
  }

  private func plan() -> Plan {
    Plan(
      title: "Week 6 for [[NAME_1]]", audience: "producers", tone: "plain",
      sections: [
        SectionSpec(
          id: "s1", heading: "Status", intent: "Report on [[NAME_1]].",
          points: ["Name the allocation."], mustInclude: ["NAME_1"], targetWords: 80
        ),
        SectionSpec(
          id: "s2", heading: "Budget", intent: "Explain [[MONEY_1]].",
          points: [], mustInclude: ["MONEY_1"], targetWords: 80
        ),
      ]
    )
  }

  func testEndToEndProducesARehydratedDocument() async throws {
    let facts = try facts()
    let writer = ScriptedWriter([
      "Dana Reyes held the week steady.",
      "The allocation stands at $1,250,000.",
    ])
    let pipeline = WritePipeline(
      planner: StubPlanner(plan: plan(), seen: { _ in }),
      writer: writer, facts: facts
    )

    let doc = try await pipeline.run(brief: "How did Dana Reyes do against $1,250,000?")

    XCTAssertEqual(doc.title, "Week 6 for Dana Reyes")
    XCTAssertEqual(doc.sections.count, 2)
    XCTAssertTrue(doc.unresolved.isEmpty, "\(doc.unresolved)")
    XCTAssertTrue(doc.markdown.contains("## Status"))
    XCTAssertTrue(doc.markdown.contains("$1,250,000"))
  }

  func testNoRealValueReachesThePlanner() async throws {
    let facts = try facts()
    let captured = LockedBox<PlanRequest?>(nil)
    let pipeline = WritePipeline(
      planner: StubPlanner(plan: plan(), seen: { captured.set($0) }),
      writer: ScriptedWriter([
        "Dana Reyes held steady.", "It stands at $1,250,000.",
      ]),
      facts: facts
    )

    _ = try await pipeline.run(brief: "How did Dana Reyes do against $1,250,000?")

    let request = try XCTUnwrap(captured.get())
    XCTAssertFalse(request.brief.contains("Dana Reyes"))
    XCTAssertFalse(request.brief.contains("1,250,000"))
    XCTAssertTrue(request.brief.contains("[[NAME_1]]"))
    XCTAssertEqual(request.catalog.map(\.id).sorted(), ["MONEY_1", "NAME_1"])
  }

  func testBriefThatCannotBeRedactedIsNeverSent() async throws {
    // A fact whose value never appears verbatim still blocks egress if a
    // reformatted form survives.
    let facts = try FactMap([
      Fact(id: "MONEY_1", kind: .money, value: "$1,250,000", label: "the allocation")
    ])
    let reached = LockedBox<Bool>(false)
    let pipeline = WritePipeline(
      planner: StubPlanner(plan: plan(), seen: { _ in reached.set(true) }),
      writer: ScriptedWriter([]), facts: facts
    )

    do {
      _ = try await pipeline.run(brief: "The team spent 1250000 this week.")
      XCTFail("expected egress to be blocked")
    } catch {
      XCTAssertEqual(error as? EgressError, .valueLeaked(id: "MONEY_1", kind: .money))
    }
    XCTAssertFalse(reached.get(), "planner must not be reached when the gate trips")
  }

  func testMissingFactTriggersARetryWithCorrections() async throws {
    let facts = try facts()
    let writer = ScriptedWriter([
      "The producer held steady.",          // omits Dana Reyes
      "Dana Reyes held steady.",            // corrected
      "It stands at $1,250,000.",
    ])
    let pipeline = WritePipeline(
      planner: StubPlanner(plan: plan(), seen: { _ in }),
      writer: writer, facts: facts, maxAttempts: 2
    )

    let doc = try await pipeline.run(brief: "Summarise the week.")

    XCTAssertEqual(doc.sections[0].attempts, 2)
    XCTAssertTrue(doc.sections[0].isClean)
    XCTAssertTrue(writer.prompts[1].contains("state exactly: Dana Reyes"))
  }

  func testUnresolvedSectionsAreReportedNotThrown() async throws {
    let facts = try facts()
    let pipeline = WritePipeline(
      planner: StubPlanner(plan: plan(), seen: { _ in }),
      writer: ScriptedWriter(["The producer held steady.", "The producer held steady.", "", ""]),
      facts: facts, maxAttempts: 2
    )

    let doc = try await pipeline.run(brief: "Summarise the week.")

    // The document still comes back; the caller decides what to do about it.
    XCTAssertEqual(doc.sections.count, 2)
    XCTAssertFalse(doc.unresolved.isEmpty)
  }

  func testSecondSectionCarriesContinuityFromTheFirst() async throws {
    let facts = try facts()
    let writer = ScriptedWriter([
      "Dana Reyes held steady.", "It stands at $1,250,000.",
    ])
    let pipeline = WritePipeline(
      planner: StubPlanner(plan: plan(), seen: { _ in }),
      writer: writer, facts: facts
    )

    _ = try await pipeline.run(brief: "Summarise the week.")

    XCTAssertFalse(writer.prompts[0].contains("THE PRECEDING SECTION ENDED"))
    XCTAssertTrue(writer.prompts[1].contains("Dana Reyes held steady."))
  }
}

/// Minimal thread-safe box so the stubs can record across the async boundary.
private final class LockedBox<T>: @unchecked Sendable {
  private var value: T
  private let lock = NSLock()
  init(_ value: T) { self.value = value }
  func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
  func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
