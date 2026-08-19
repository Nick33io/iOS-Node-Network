import Foundation

/// A fact as the cloud is allowed to see it: shape and purpose, never value.
public struct FactDescriptor: Codable, Sendable, Equatable {
  public let id: String
  public let kind: FactKind
  public let label: String

  public init(id: String, kind: FactKind, label: String) {
    self.id = id
    self.kind = kind
    self.label = label
  }
}

extension FactMap {
  /// The value-free projection of this map. This is the only form of the fact
  /// set permitted to egress.
  public var catalog: [FactDescriptor] {
    facts.map { FactDescriptor(id: $0.id, kind: $0.kind, label: $0.label) }
  }
}

/// Everything the planner receives. By construction it holds no real values:
/// `brief` has been through `Abstractor.sealed`, and `catalog` is value-free.
public struct PlanRequest: Sendable {
  public let brief: String
  public let catalog: [FactDescriptor]
  public let wordBudgetPerSection: Int
  public let targetWords: Int?

  public init(
    brief: String,
    catalog: [FactDescriptor],
    wordBudgetPerSection: Int,
    targetWords: Int?
  ) {
    self.brief = brief
    self.catalog = catalog
    self.wordBudgetPerSection = wordBudgetPerSection
    self.targetWords = targetWords
  }
}

/// Reasons in the cloud. Sees placeholders and labels only.
public protocol CloudPlanner: Sendable {
  func plan(_ request: PlanRequest) async throws -> Plan
}

/// Writes on the device. Sees real values; never touches the network.
public protocol DeviceWriter: Sendable {
  var limits: DeviceLimits { get }
  func generate(prompt: String, maxOutputTokens: Int) async throws -> String
}
