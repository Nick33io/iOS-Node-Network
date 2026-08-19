import XCTest
@testable import WriteCore

final class SectionPromptTests: XCTestCase {
  private let limits = DeviceLimits.qwen3_4B_4bit

  func testPromptStaysInsideTheCharacterBudget() throws {
    let builder = SectionPromptBuilder(limits: limits)
    let spec = SectionSpec(
      id: "s1", heading: "Overview", intent: "Summarise the week.",
      points: ["Cover the schedule.", "Name the blocker."],
      mustInclude: [], targetWords: 200
    )
    let prompt = try builder.prompt(for: spec, previousTail: String(repeating: "tail ", count: 400))
    XCTAssertLessThanOrEqual(prompt.count, limits.maxInputCharacters)
  }

  func testContinuityIsIncludedWhenItFits() throws {
    let builder = SectionPromptBuilder(limits: limits)
    let spec = SectionSpec(
      id: "s1", heading: "Overview", intent: "Continue.",
      points: [], mustInclude: [], targetWords: 200
    )
    let prompt = try builder.prompt(for: spec, previousTail: "The prior section closed here.")
    XCTAssertTrue(prompt.contains("THE PRECEDING SECTION ENDED"))
  }

  func testContinuityIsDroppedRatherThanOverflowing() throws {
    let builder = SectionPromptBuilder(limits: limits, continuityBudget: 4000)
    let spec = SectionSpec(
      id: "s1", heading: "Overview", intent: String(repeating: "detail ", count: 380),
      points: [], mustInclude: [], targetWords: 200
    )
    let prompt = try builder.prompt(for: spec, previousTail: String(repeating: "tail ", count: 400))
    XCTAssertFalse(prompt.contains("THE PRECEDING SECTION ENDED"))
    XCTAssertLessThanOrEqual(prompt.count, limits.maxInputCharacters)
  }

  func testSectionThatCannotFitIsRejected() {
    let builder = SectionPromptBuilder(limits: limits)
    let spec = SectionSpec(
      id: "s1", heading: "Overview", intent: String(repeating: "x", count: 4000),
      points: [], mustInclude: [], targetWords: 200
    )
    XCTAssertThrowsError(try builder.prompt(for: spec, previousTail: nil)) { error in
      guard case .overBudget(let section, _, let limit)? = error as? PromptError else {
        return XCTFail("expected overBudget, got \(error)")
      }
      XCTAssertEqual(section, "s1")
      XCTAssertEqual(limit, limits.maxInputCharacters)
    }
  }

  func testClipStartsOnAWordBoundary() {
    let clipped = SectionPromptBuilder.clipToWordBoundary("alpha beta gamma delta", limit: 12)
    XCTAssertFalse(clipped.hasPrefix("ta "))
    XCTAssertTrue("alpha beta gamma delta".hasSuffix(clipped))
  }
}
