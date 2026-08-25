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

/// Generated text with a real token count when the backend knows one.
///
/// `tokens` is optional rather than computed because only some backends can
/// answer honestly: `mlx_lm.server` returns `usage.completion_tokens`, while a
/// writer that only hands back a string cannot. A nil here means "ask the
/// estimator", and the estimator is wrong — measured 5.4 characters per token
/// against the 4 that was assumed — so nil should be the exception.
public struct Generation: Sendable {
  public let text: String
  public let tokens: Int?

  public init(text: String, tokens: Int? = nil) {
    self.text = text
    self.tokens = tokens
  }
}

/// Writes on the device. Sees real values; never touches the network.
public protocol DeviceWriter: Sendable {
  var limits: DeviceLimits { get }
  func generate(prompt: String, maxOutputTokens: Int) async throws -> String

  /// Generation plus a token count when the backend reports one.
  ///
  /// Declared here, not only in the extension. A method that exists solely in
  /// a protocol extension is statically dispatched, so calling it through an
  /// `any DeviceWriter` runs the default and never the conforming type's
  /// override — which is exactly what happened: the node kept reporting the
  /// character estimate while `MLXServerWriter` had the server's real count
  /// sitting unused, and every throughput figure stayed 1.28x high.
  func generateDetailed(prompt: String, maxOutputTokens: Int) async throws -> Generation
}

extension DeviceWriter {
  /// Default for writers that cannot count: text only, no token figure.
  public func generateDetailed(
    prompt: String, maxOutputTokens: Int
  ) async throws -> Generation {
    Generation(text: try await generate(prompt: prompt, maxOutputTokens: maxOutputTokens))
  }
}
