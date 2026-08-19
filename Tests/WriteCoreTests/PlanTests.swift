import XCTest
@testable import WriteCore

final class PlanTests: XCTestCase {
  private let limits = DeviceLimits.qwen3_4B_4bit

  private func facts() throws -> FactMap {
    try FactMap([Fact(id: "NAME_1", kind: .name, value: "Dana Reyes", label: "the line producer")])
  }

  private func section(
    id: String = "s1",
    intent: String = "Open the memo.",
    mustInclude: [String] = [],
    targetWords: Int = 200
  ) -> SectionSpec {
    SectionSpec(
      id: id, heading: "Overview", intent: intent,
      points: [], mustInclude: mustInclude, targetWords: targetWords
    )
  }

  func testAcceptsAWellFormedPlan() throws {
    let plan = Plan(
      title: "Weekly memo", audience: "producers", tone: "plain",
      sections: [section(intent: "Summarise [[NAME_1]]'s week.", mustInclude: ["NAME_1"])]
    )
    XCTAssertNoThrow(try plan.validate(against: try facts(), limits: limits))
  }

  func testRejectsHallucinatedPlaceholder() throws {
    let plan = Plan(
      title: "Memo", audience: "producers", tone: "plain",
      sections: [section(intent: "Summarise [[NAME_9]]'s week.")]
    )
    XCTAssertThrowsError(try plan.validate(against: try facts(), limits: limits)) { error in
      XCTAssertEqual(error as? PlanError, .unknownPlaceholder("NAME_9"))
    }
  }

  func testRejectsSectionLongerThanOneGenerateCall() throws {
    let plan = Plan(
      title: "Memo", audience: "producers", tone: "plain",
      sections: [section(targetWords: 900)]
    )
    XCTAssertThrowsError(try plan.validate(against: try facts(), limits: limits)) { error in
      XCTAssertEqual(
        error as? PlanError,
        .sectionTooLong(section: "s1", words: 900, budget: limits.wordBudgetPerSection)
      )
    }
  }

  func testRejectsDuplicateSectionIDs() throws {
    let plan = Plan(
      title: "Memo", audience: "producers", tone: "plain",
      sections: [section(id: "s1"), section(id: "s1")]
    )
    XCTAssertThrowsError(try plan.validate(against: try facts(), limits: limits)) { error in
      XCTAssertEqual(error as? PlanError, .duplicateSectionID("s1"))
    }
  }

  func testRejectsUnknownRequiredFact() throws {
    let plan = Plan(
      title: "Memo", audience: "producers", tone: "plain",
      sections: [section(mustInclude: ["MONEY_4"])]
    )
    XCTAssertThrowsError(try plan.validate(against: try facts(), limits: limits)) { error in
      XCTAssertEqual(error as? PlanError, .unknownFact(section: "s1", id: "MONEY_4"))
    }
  }
}
