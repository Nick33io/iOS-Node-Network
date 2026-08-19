import Foundation

/// What went wrong with a generated section.
public enum Issue: Sendable, Equatable, CustomStringConvertible {
  case empty
  case missingFact(id: String, value: String)
  case residualPlaceholder(String)
  case overLength(words: Int, target: Int)
  case unsupportedNumber(String)

  public var description: String {
    switch self {
    case .empty:
      return "Section is empty."
    case .missingFact(let id, _):
      return "Required fact '\(id)' does not appear in the section."
    case .residualPlaceholder(let id):
      return "Placeholder '\(id)' was never rehydrated."
    case .overLength(let words, let target):
      return "Section ran to \(words) words against a target of \(target)."
    case .unsupportedNumber(let number):
      return "Section states '\(number)', which appears in neither the facts nor the plan."
    }
  }

  /// Whether this issue should trigger a regeneration.
  ///
  /// Length is advisory — a section that runs long is still deliverable, and
  /// burning a retry on it costs more than it saves.
  public var warrantsRetry: Bool {
    switch self {
    case .empty, .missingFact, .residualPlaceholder, .unsupportedNumber: return true
    case .overLength: return false
    }
  }
}

/// Deterministic post-generation checks.
///
/// Nothing here calls a model. A 4B model's characteristic failure is inventing
/// specifics, and specifics are exactly what string and numeric matching catch
/// for free. Anything needing judgement is deliberately out of scope.
public struct Verifier: Sendable {
  public let facts: FactMap
  /// Multiple of `targetWords` past which a section counts as over-length.
  public let lengthTolerance: Double

  public init(facts: FactMap, lengthTolerance: Double = 1.6) {
    self.facts = facts
    self.lengthTolerance = lengthTolerance
  }

  /// - Parameter text: the rehydrated section.
  public func verify(_ text: String, against section: SectionSpec) -> [Issue] {
    var issues: [Issue] = []
    let trimmed = text.trimmed

    guard !trimmed.isEmpty else { return [.empty] }

    let haystack = trimmed.lowercased()
    for id in section.mustInclude {
      guard let fact = facts[id] else { continue }
      if !haystack.contains(fact.value.lowercased()) {
        issues.append(.missingFact(id: id, value: fact.value))
      }
    }

    for id in Abstractor.scanPlaceholders(trimmed) {
      issues.append(.residualPlaceholder(id))
    }

    let words = trimmed.split(whereSeparator: \.isWhitespace).count
    if Double(words) > Double(section.targetWords) * lengthTolerance {
      issues.append(.overLength(words: words, target: section.targetWords))
    }

    for number in Self.unsupportedNumbers(in: trimmed, section: section, facts: facts) {
      issues.append(.unsupportedNumber(number))
    }

    return issues
  }

  /// Numbers the model produced that trace back to nothing we supplied.
  ///
  /// Only tokens of three or more digits are considered. Below that the model is
  /// almost always writing ordinary prose ("three or four weeks", "the first
  /// two"), and flagging it would bury the real hallucinations in noise.
  static func unsupportedNumbers(
    in text: String,
    section: SectionSpec,
    facts: FactMap
  ) -> [String] {
    var supported = Set<String>()
    for fact in facts.facts {
      supported.formUnion(numericTokens(in: fact.value))
    }
    for field in section.textualFields {
      supported.formUnion(numericTokens(in: field))
    }
    supported.insert(String(section.targetWords))

    var seen = Set<String>()
    var out: [String] = []
    for token in numericTokens(in: text) where token.count >= 3 {
      guard !supported.contains(token), seen.insert(token).inserted else { continue }
      out.append(token)
    }
    return out
  }

  /// Digit runs, with separators removed so "1,250" and "1250" compare equal.
  static func numericTokens(in text: String) -> Set<String> {
    var tokens = Set<String>()
    var current = ""
    for character in text {
      if character.isNumber {
        current.append(character)
      } else if character == "," || character == "." {
        // Keep the run going across separators inside a number, but only if we
        // are already inside one.
        if current.isEmpty { continue }
      } else if !current.isEmpty {
        tokens.insert(current)
        current = ""
      }
    }
    if !current.isEmpty { tokens.insert(current) }
    return tokens
  }
}
