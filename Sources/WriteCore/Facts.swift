import Foundation

/// What a fact is, so the planner can reason about shape without seeing value.
public enum FactKind: String, Codable, Sendable, CaseIterable {
  case name, org, money, number, date, location, other

  /// Kinds whose values need numeric normalisation during leak detection,
  /// because the same quantity has many surface forms ("$1,250,000", "1250000").
  var isNumeric: Bool {
    switch self {
    case .money, .number: return true
    case .name, .org, .date, .location, .other: return false
    }
  }
}

/// A single real value that must never reach the cloud.
///
/// `value` stays on device. `label` is the neutral stand-in description that
/// egresses in its place, so the planner can still reason about the slot.
public struct Fact: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: FactKind
  public let value: String
  public let label: String

  public init(id: String, kind: FactKind, value: String, label: String) {
    self.id = id
    self.kind = kind
    self.value = value
    self.label = label
  }

  public var placeholder: String { "[[\(id)]]" }
}

public struct FactMap: Sendable {
  public let facts: [Fact]
  private let index: [String: Fact]

  public init(_ facts: [Fact]) throws {
    var index: [String: Fact] = [:]
    for fact in facts {
      guard FactMap.isValidID(fact.id) else {
        throw FactError.malformedID(fact.id)
      }
      guard index[fact.id] == nil else {
        throw FactError.duplicateID(fact.id)
      }
      guard !fact.value.trimmed.isEmpty else {
        throw FactError.emptyValue(fact.id)
      }
      index[fact.id] = fact
    }
    self.facts = facts
    self.index = index
  }

  public subscript(id: String) -> Fact? { index[id] }
  public var ids: Set<String> { Set(index.keys) }
  public var isEmpty: Bool { facts.isEmpty }

  /// Facts ordered longest-value-first.
  ///
  /// Redaction must consume "Acme Studios Ltd" before "Acme", or the shorter
  /// match leaves "` Studios Ltd`" stranded in the redacted text and the
  /// remainder egresses.
  var byDescendingValueLength: [Fact] {
    facts.sorted { $0.value.count > $1.value.count }
  }

  /// `NAME_1`, `MONEY_12` — uppercase tag, underscore, digits.
  static func isValidID(_ id: String) -> Bool {
    guard let underscore = id.lastIndex(of: "_") else { return false }
    let tag = id[id.startIndex..<underscore]
    let number = id[id.index(after: underscore)...]
    guard !tag.isEmpty, !number.isEmpty else { return false }
    guard tag.allSatisfy({ $0.isUppercase && $0.isLetter }) else { return false }
    return number.allSatisfy(\.isNumber)
  }
}

public enum FactError: Error, Equatable, CustomStringConvertible {
  case malformedID(String)
  case duplicateID(String)
  case emptyValue(String)

  public var description: String {
    switch self {
    case .malformedID(let id):
      return "Fact id '\(id)' is malformed; expected an uppercase tag, an underscore, and digits (e.g. NAME_1)."
    case .duplicateID(let id):
      return "Fact id '\(id)' is declared more than once."
    case .emptyValue(let id):
      return "Fact '\(id)' has an empty value; it would redact to nothing."
    }
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
