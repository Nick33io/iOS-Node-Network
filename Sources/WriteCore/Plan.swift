import Foundation

/// One unit of device work. Sized so a single `generate` call can complete it.
public struct SectionSpec: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let heading: String
  public let intent: String
  public let points: [String]
  /// Fact ids that must appear in the finished section. The verifier enforces
  /// this against the rehydrated text, which is what makes the check cheap and
  /// deterministic rather than another model call.
  public let mustInclude: [String]
  public let targetWords: Int

  public init(
    id: String,
    heading: String,
    intent: String,
    points: [String],
    mustInclude: [String],
    targetWords: Int
  ) {
    self.id = id
    self.heading = heading
    self.intent = intent
    self.points = points
    self.mustInclude = mustInclude
    self.targetWords = targetWords
  }

  /// Every span of this spec that may carry placeholders.
  var textualFields: [String] { [heading, intent] + points }
}

/// What the cloud returns. Contains placeholders, never values.
public struct Plan: Codable, Sendable, Equatable {
  public let title: String
  public let audience: String
  public let tone: String
  public let sections: [SectionSpec]

  public init(title: String, audience: String, tone: String, sections: [SectionSpec]) {
    self.title = title
    self.audience = audience
    self.tone = tone
    self.sections = sections
  }

  var textualFields: [String] {
    [title, audience, tone] + sections.flatMap(\.textualFields)
  }

  /// Reject a plan the device cannot execute, or that refers to slots we never
  /// issued.
  ///
  /// This runs before any generation. A plan that fails here is a planner bug
  /// or a hallucination, and retrying generation would not fix it.
  public func validate(against facts: FactMap, limits: DeviceLimits) throws {
    guard !sections.isEmpty else { throw PlanError.noSections }

    var seen = Set<String>()
    for section in sections {
      guard seen.insert(section.id).inserted else {
        throw PlanError.duplicateSectionID(section.id)
      }
      guard !section.heading.trimmed.isEmpty else {
        throw PlanError.emptyHeading(section.id)
      }
      guard section.targetWords > 0 else {
        throw PlanError.nonPositiveTarget(section: section.id, words: section.targetWords)
      }
      guard section.targetWords <= limits.wordBudgetPerSection else {
        throw PlanError.sectionTooLong(
          section: section.id,
          words: section.targetWords,
          budget: limits.wordBudgetPerSection
        )
      }
      for id in section.mustInclude where facts[id] == nil {
        throw PlanError.unknownFact(section: section.id, id: id)
      }
    }

    // A placeholder anywhere in the plan that we never issued would rehydrate
    // to nothing and leave a literal `[[…]]` in the delivered document.
    let known = facts.ids
    for field in textualFields {
      for id in Abstractor.scanPlaceholders(field) where !known.contains(id) {
        throw PlanError.unknownPlaceholder(id)
      }
    }
  }
}

public enum PlanError: Error, Equatable, CustomStringConvertible {
  case noSections
  case duplicateSectionID(String)
  case emptyHeading(String)
  case nonPositiveTarget(section: String, words: Int)
  case sectionTooLong(section: String, words: Int, budget: Int)
  case unknownFact(section: String, id: String)
  case unknownPlaceholder(String)

  public var description: String {
    switch self {
    case .noSections:
      return "Plan contains no sections."
    case .duplicateSectionID(let id):
      return "Plan reuses section id '\(id)'."
    case .emptyHeading(let id):
      return "Section '\(id)' has an empty heading."
    case .nonPositiveTarget(let section, let words):
      return "Section '\(section)' asks for \(words) words."
    case .sectionTooLong(let section, let words, let budget):
      return "Section '\(section)' asks for \(words) words; one generate call yields at most \(budget)."
    case .unknownFact(let section, let id):
      return "Section '\(section)' requires fact '\(id)', which was never issued."
    case .unknownPlaceholder(let id):
      return "Plan references placeholder '\(id)', which was never issued."
    }
  }
}
