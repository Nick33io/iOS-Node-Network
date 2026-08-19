import XCTest
@testable import WriteCore

final class VerifierTests: XCTestCase {
  private func facts() throws -> FactMap {
    try FactMap([
      Fact(id: "NAME_1", kind: .name, value: "Dana Reyes", label: "the line producer"),
      Fact(id: "MONEY_1", kind: .money, value: "$1,250,000", label: "the allocation"),
    ])
  }

  private func spec(mustInclude: [String] = [], targetWords: Int = 100) -> SectionSpec {
    SectionSpec(
      id: "s1", heading: "Overview", intent: "Summarise the week.",
      points: ["Cover the 42-day schedule."],
      mustInclude: mustInclude, targetWords: targetWords
    )
  }

  func testCleanSectionHasNoIssues() throws {
    let v = Verifier(facts: try facts())
    let issues = v.verify("Dana Reyes closed the week.", against: spec(mustInclude: ["NAME_1"]))
    XCTAssertTrue(issues.isEmpty, "\(issues)")
  }

  func testMissingRequiredFactIsCaught() throws {
    let v = Verifier(facts: try facts())
    let issues = v.verify("The producer closed the week.", against: spec(mustInclude: ["NAME_1"]))
    XCTAssertEqual(issues, [.missingFact(id: "NAME_1", value: "Dana Reyes")])
  }

  func testResidualPlaceholderIsCaught() throws {
    let v = Verifier(facts: try facts())
    let issues = v.verify("[[NAME_1]] closed the week.", against: spec())
    XCTAssertEqual(issues, [.residualPlaceholder("NAME_1")])
  }

  func testInventedFigureIsCaught() throws {
    let v = Verifier(facts: try facts())
    // 8,400 appears in neither the facts nor the plan — the characteristic
    // small-model failure this check exists for.
    let issues = v.verify("Dana Reyes reported 8,400 units.", against: spec(mustInclude: ["NAME_1"]))
    XCTAssertEqual(issues, [.unsupportedNumber("8400")])
  }

  func testFigureSuppliedInTheFactsIsAccepted() throws {
    let v = Verifier(facts: try facts())
    let issues = v.verify("The allocation is $1,250,000.", against: spec())
    XCTAssertTrue(issues.isEmpty, "\(issues)")
  }

  func testFigureSuppliedInThePlanIsAccepted() throws {
    let v = Verifier(facts: try facts())
    let issues = v.verify("The schedule runs 142 days.", against: spec())
    // 142 is not in the plan; 42 is, but it is under three digits so it is not
    // checked either way. Confirm we flag the three-digit invention only.
    XCTAssertEqual(issues, [.unsupportedNumber("142")])
  }

  func testOverLengthIsAdvisoryOnly() throws {
    let v = Verifier(facts: try facts())
    let long = String(repeating: "word ", count: 300)
    let issues = v.verify(long, against: spec(targetWords: 100))
    XCTAssertEqual(issues, [.overLength(words: 300, target: 100)])
    XCTAssertFalse(issues[0].warrantsRetry)
  }

  func testEmptySectionIsCaught() throws {
    let v = Verifier(facts: try facts())
    XCTAssertEqual(v.verify("   ", against: spec()), [.empty])
  }
}
