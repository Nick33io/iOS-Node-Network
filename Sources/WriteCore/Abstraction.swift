import Foundation

/// The egress boundary.
///
/// Everything that crosses to the cloud passes through `redact` and then
/// `assertNoLeak`. `assertNoLeak` is not a second opinion on `redact` — it is
/// the actual gate. `redact` is allowed to be imperfect; the gate is not
/// allowed to pass a leak. Callers must treat a thrown `EgressError` as fatal
/// for that request rather than retrying against the same text.
public struct Abstractor: Sendable {
  public let facts: FactMap

  public init(facts: FactMap) {
    self.facts = facts
  }

  // MARK: Outbound

  /// Replace every real value with its placeholder.
  ///
  /// Matching is case-insensitive, longest-value-first, and bounded to token
  /// edges. The placeholder is emitted in canonical form regardless of source
  /// casing, so `Acme` and `ACME` both become `[[ORG_1]]`.
  public func redact(_ text: String) -> String {
    var out = text
    for fact in facts.byDescendingValueLength {
      out = Abstractor.replaceOnBoundaries(fact.value, with: fact.placeholder, in: out)
    }
    return out
  }

  /// Fail closed if any real value survived redaction.
  ///
  /// Two passes: boundary-aware containment for every fact, plus a digits-only
  /// pass for numeric kinds so that reformatted quantities ("$1,250,000"
  /// against a stored "1250000") are still caught.
  ///
  /// The first pass uses the same boundary rule as `redact`, deliberately. A
  /// stricter gate than the redactor would make `sealed` unable to pass any
  /// text containing a value embedded inside a longer word — the system would
  /// fail closed on everything, which is the same as not shipping. A value
  /// occurring inside a larger token is therefore out of scope by design.
  public func assertNoLeak(_ text: String) throws {
    let digitsOnlyHaystack = Abstractor.digitsOnly(text)

    for fact in facts.facts {
      if Abstractor.containsOnBoundaries(fact.value, in: text) {
        throw EgressError.valueLeaked(id: fact.id, kind: fact.kind)
      }
      guard fact.kind.isNumeric else { continue }
      let digits = Abstractor.digitsOnly(fact.value)
      // Fewer than three digits is not identifying, and matching on it would
      // fire on ordinary prose ("in 12 weeks"). Skip rather than block.
      guard digits.count >= 3 else { continue }
      if digitsOnlyHaystack.contains(digits) {
        throw EgressError.valueLeaked(id: fact.id, kind: fact.kind)
      }
    }
  }

  /// Redact and gate in one step. This is the only sanctioned way to build an
  /// egress payload.
  public func sealed(_ text: String) throws -> String {
    let redacted = redact(text)
    try assertNoLeak(redacted)
    return redacted
  }

  // MARK: Inbound

  /// Replace placeholders with real values. Device-side only.
  public func rehydrate(_ text: String) -> String {
    var out = text
    for fact in facts.facts {
      out = out.replacingOccurrences(of: fact.placeholder, with: fact.value)
    }
    return out
  }

  /// Placeholder ids the text refers to, whether or not they are known.
  ///
  /// Used to catch a planner that invented a slot we never gave it — a
  /// hallucinated `[[NAME_9]]` would otherwise rehydrate to nothing and leave
  /// a hole in the document.
  public func referencedIDs(in text: String) -> Set<String> {
    Set(Abstractor.scanPlaceholders(text))
  }

  /// Placeholders still present after rehydration. Non-empty means the output
  /// is not deliverable.
  public func residualPlaceholders(in text: String) -> [String] {
    Abstractor.scanPlaceholders(text)
  }

  // MARK: Scanning

  /// Find `[[ID]]` occurrences. Hand-rolled rather than regex so the scan has
  /// no locale or backtracking behaviour to reason about.
  static func scanPlaceholders(_ text: String) -> [String] {
    var found: [String] = []
    let chars = Array(text)
    var i = 0
    while i + 3 < chars.count {
      guard chars[i] == "[", chars[i + 1] == "[" else {
        i += 1
        continue
      }
      var j = i + 2
      var id = ""
      while j + 1 < chars.count, !(chars[j] == "]" && chars[j + 1] == "]") {
        id.append(chars[j])
        j += 1
      }
      // Unterminated `[[` — stop treating it as a placeholder and move on.
      guard j + 1 < chars.count else {
        i += 1
        continue
      }
      if FactMap.isValidID(id) {
        found.append(id)
      }
      i = j + 2
    }
    return found
  }

  /// Case-insensitive replacement that only fires when the match is flanked by
  /// non-word characters.
  ///
  /// Without this, a fact valued "12" rewrites "2012" into "20[[NUMBER_1]]",
  /// and a fact valued "Acme" corrupts "Acmeworks". Short numeric values make
  /// this failure routine rather than exotic.
  static func replaceOnBoundaries(
    _ value: String,
    with replacement: String,
    in text: String
  ) -> String {
    guard !value.isEmpty else { return text }
    let chars = Array(text)
    let needle = value.lowercased()
    let width = value.count
    var out = ""
    var i = 0
    while i < chars.count {
      if matches(needle, width: width, in: chars, at: i) {
        out += replacement
        i += width
      } else {
        out.append(chars[i])
        i += 1
      }
    }
    return out
  }

  static func containsOnBoundaries(_ value: String, in text: String) -> Bool {
    guard !value.isEmpty else { return false }
    let chars = Array(text)
    let needle = value.lowercased()
    let width = value.count
    for i in chars.indices where matches(needle, width: width, in: chars, at: i) {
      return true
    }
    return false
  }

  /// Compares by building a `String` rather than indexing a parallel lowercased
  /// array, because lowercasing can change a string's character count. If it
  /// does, the comparison simply fails — the redactor leaves the text alone and
  /// the gate then blocks it, which is the safe direction.
  private static func matches(
    _ lowercasedNeedle: String,
    width: Int,
    in chars: [Character],
    at index: Int
  ) -> Bool {
    guard index + width <= chars.count else { return false }
    guard String(chars[index..<(index + width)]).lowercased() == lowercasedNeedle else {
      return false
    }
    let precededByWord = index > 0 && isWordCharacter(chars[index - 1])
    let followedByWord = index + width < chars.count && isWordCharacter(chars[index + width])
    return !precededByWord && !followedByWord
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
  }

  static func digitsOnly(_ text: String) -> String {
    String(text.filter(\.isNumber))
  }
}

public enum EgressError: Error, Equatable, CustomStringConvertible {
  case valueLeaked(id: String, kind: FactKind)

  public var description: String {
    switch self {
    case .valueLeaked(let id, let kind):
      return "Egress blocked: the value for \(kind.rawValue) fact '\(id)' survived redaction."
    }
  }
}
