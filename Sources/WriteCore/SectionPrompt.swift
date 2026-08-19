import Foundation

/// Assembles the per-section device prompt inside the character budget.
///
/// The KV cache is cleared before every generation, so nothing carries over
/// implicitly between sections. Continuity has to be spelled out in the prompt
/// or it does not exist. That is the reason `previousTail` is a parameter and
/// not an optimisation.
///
/// Only the character cap is enforced here — the token cap is enforced natively
/// where a tokenizer is available. The two are close for English prose, and the
/// device writer rejects anything that slips through.
public struct SectionPromptBuilder: Sendable {
  public let limits: DeviceLimits
  /// Characters of the preceding section carried forward for continuity.
  public let continuityBudget: Int

  public init(limits: DeviceLimits, continuityBudget: Int = 400) {
    self.limits = limits
    self.continuityBudget = continuityBudget
  }

  /// Fixed instructions. Kept terse because every character here is a character
  /// the section spec cannot use.
  static let systemInstructions = """
    You write one section of a longer document. Write only that section's prose.
    Do not restate the heading, do not add a preamble, and do not write any
    other section. Use every required detail exactly as given; never invent
    names, figures, or dates that are not supplied.
    """

  /// - Parameters:
  ///   - section: a spec whose placeholders have already been rehydrated.
  ///   - previousTail: closing text of the previous section, already rehydrated.
  public func prompt(for section: SectionSpec, previousTail: String?) throws -> String {
    let head = Self.systemInstructions

    var body = """

      SECTION: \(section.heading)
      GOAL: \(section.intent)
      LENGTH: about \(section.targetWords) words.
      """

    if !section.points.isEmpty {
      let points = section.points.map { "- \($0)" }.joined(separator: "\n")
      body += "\n\nCOVER:\n\(points)"
    }

    let fixed = head + body
    var prompt = fixed

    // Continuity is the first thing sacrificed when the budget is tight: losing
    // it degrades the seam between sections, whereas losing a required point
    // would fail verification outright.
    if let tail = previousTail?.trimmed, !tail.isEmpty {
      let clipped = Self.clipToWordBoundary(tail, limit: continuityBudget)
      let candidate = fixed + "\n\nTHE PRECEDING SECTION ENDED:\n\(clipped)\n\nContinue from there without repeating it."
      if candidate.count <= limits.maxInputCharacters {
        prompt = candidate
      }
    }

    guard prompt.count <= limits.maxInputCharacters else {
      throw PromptError.overBudget(
        section: section.id,
        characters: prompt.count,
        limit: limits.maxInputCharacters
      )
    }
    return prompt
  }

  /// Trim to the last `limit` characters, then forward to a word boundary so
  /// the carried tail does not begin mid-word.
  static func clipToWordBoundary(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let tail = String(text.suffix(limit))
    guard let space = tail.firstIndex(where: \.isWhitespace) else { return tail }
    return String(tail[tail.index(after: space)...]).trimmed
  }
}

public enum PromptError: Error, Equatable, CustomStringConvertible {
  case overBudget(section: String, characters: Int, limit: Int)

  public var description: String {
    switch self {
    case .overBudget(let section, let characters, let limit):
      return "Section '\(section)' builds a \(characters)-character prompt; the device accepts \(limit). Split the section."
    }
  }
}
