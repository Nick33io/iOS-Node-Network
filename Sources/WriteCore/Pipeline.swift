import Foundation

public struct WrittenSection: Sendable, Equatable {
  public let id: String
  public let heading: String
  public let text: String
  public let attempts: Int
  public let issues: [Issue]

  public var isClean: Bool { issues.isEmpty }
}

public struct WrittenDocument: Sendable, Equatable {
  public let title: String
  public let sections: [WrittenSection]

  /// Sections that still carry retry-worthy issues after every attempt.
  public var unresolved: [WrittenSection] {
    sections.filter { $0.issues.contains(where: \.warrantsRetry) }
  }

  public var markdown: String {
    var out = "# \(title)\n"
    for section in sections {
      out += "\n## \(section.heading)\n\n\(section.text)\n"
    }
    return out
  }
}

/// Plan in the cloud, write on the device, verify locally.
///
/// The ordering is load-bearing. The brief is sealed before the planner is
/// reached, the plan is validated before any generation, and the plan is
/// rehydrated only after validation — so real values enter the process at the
/// last possible moment and never travel back out.
public struct WritePipeline: Sendable {
  public let planner: CloudPlanner
  public let writer: DeviceWriter
  public let facts: FactMap
  public let maxAttempts: Int

  public init(
    planner: CloudPlanner,
    writer: DeviceWriter,
    facts: FactMap,
    maxAttempts: Int = 2
  ) {
    self.planner = planner
    self.writer = writer
    self.facts = facts
    self.maxAttempts = maxAttempts
  }

  public func run(
    brief: String,
    targetWords: Int? = nil,
    onSection: (@Sendable (WrittenSection) -> Void)? = nil
  ) async throws -> WrittenDocument {
    let abstractor = Abstractor(facts: facts)
    let limits = writer.limits

    let sealed = try abstractor.sealed(brief)
    let plan = try await planner.plan(
      PlanRequest(
        brief: sealed,
        catalog: facts.catalog,
        wordBudgetPerSection: limits.wordBudgetPerSection,
        targetWords: targetWords
      )
    )
    try plan.validate(against: facts, limits: limits)

    let builder = SectionPromptBuilder(limits: limits)
    let verifier = Verifier(facts: facts)

    var written: [WrittenSection] = []
    var tail: String?

    for spec in plan.sections {
      let local = rehydrate(spec, with: abstractor)
      let section = try await write(
        local,
        previousTail: tail,
        builder: builder,
        verifier: verifier
      )
      written.append(section)
      onSection?(section)
      tail = section.text
    }

    return WrittenDocument(title: abstractor.rehydrate(plan.title), sections: written)
  }

  // MARK: Internals

  private func write(
    _ spec: SectionSpec,
    previousTail: String?,
    builder: SectionPromptBuilder,
    verifier: Verifier
  ) async throws -> WrittenSection {
    let base = try builder.prompt(for: spec, previousTail: previousTail)
    var best: (text: String, issues: [Issue])?

    for attempt in 1...max(1, maxAttempts) {
      var prompt = base
      // On a retry, name what was missed. Only if it fits — the budget is the
      // budget, and a truncated prompt is worse than an unguided retry.
      if let previous = best?.issues, !previous.isEmpty {
        let addendum = Self.corrections(for: previous)
        if !addendum.isEmpty, (base + addendum).count <= builder.limits.maxInputCharacters {
          prompt = base + addendum
        }
      }

      let raw = try await writer.generate(
        prompt: prompt,
        maxOutputTokens: builder.limits.maxOutputTokens
      )
      let text = raw.trimmed
      let issues = verifier.verify(text, against: spec)

      if issues.isEmpty {
        return WrittenSection(
          id: spec.id, heading: spec.heading, text: text,
          attempts: attempt, issues: []
        )
      }
      // Keep the attempt with the fewest retry-worthy issues.
      let score = issues.filter(\.warrantsRetry).count
      let bestScore = best?.issues.filter(\.warrantsRetry).count ?? Int.max
      if score < bestScore { best = (text, issues) }
      if !issues.contains(where: \.warrantsRetry) { break }
    }

    let resolved = best ?? (text: "", issues: [Issue.empty])
    return WrittenSection(
      id: spec.id, heading: spec.heading, text: resolved.text,
      attempts: max(1, maxAttempts), issues: resolved.issues
    )
  }

  private func rehydrate(_ spec: SectionSpec, with abstractor: Abstractor) -> SectionSpec {
    SectionSpec(
      id: spec.id,
      heading: abstractor.rehydrate(spec.heading),
      intent: abstractor.rehydrate(spec.intent),
      points: spec.points.map(abstractor.rehydrate),
      mustInclude: spec.mustInclude,
      targetWords: spec.targetWords
    )
  }

  static func corrections(for issues: [Issue]) -> String {
    var lines: [String] = []
    for issue in issues {
      switch issue {
      case .missingFact(_, let value):
        lines.append("- state exactly: \(value)")
      case .unsupportedNumber(let number):
        lines.append("- remove the figure \(number); it was not supplied")
      case .empty, .residualPlaceholder, .overLength:
        continue
      }
    }
    guard !lines.isEmpty else { return "" }
    return "\n\nThe previous attempt was rejected. Fix these:\n" + lines.joined(separator: "\n")
  }
}
