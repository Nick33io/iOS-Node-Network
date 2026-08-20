import Foundation

/// A participant in the mesh, coordinator included.
///
/// A struct rather than a bare `String` so an item id can never be passed
/// where a node id belongs — the two travel together in every message.
public struct NodeID: Hashable, Sendable, Comparable, CustomStringConvertible,
  ExpressibleByStringLiteral
{
  public let raw: String

  public init(_ raw: String) { self.raw = raw }
  public init(stringLiteral value: String) { self.init(value) }

  public var description: String { raw }
  public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.raw < rhs.raw }
}

extension NodeID: Codable {
  // Single-value coding, so the wire carries "n1" rather than {"raw":"n1"}.
  public init(from decoder: Decoder) throws {
    self.raw = try decoder.singleValueContainer().decode(String.self)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(raw)
  }
}

/// A point on the coordinator's monotonic clock.
///
/// Ticks, not wall time: leases and heartbeat timeouts only ever compare
/// instants from the same injected clock, so nothing here needs `Date` — and
/// tests can advance time by assignment instead of sleeping.
public struct MeshTick: Codable, Sendable, Equatable, Comparable {
  public let value: Int

  public init(_ value: Int) { self.value = value }

  public func advanced(by ticks: Int) -> MeshTick { MeshTick(value + ticks) }
  public static func < (lhs: MeshTick, rhs: MeshTick) -> Bool { lhs.value < rhs.value }
}

/// The completed output of a dependency, carried inside an offer.
///
/// Handoffs travel with the offer so the claiming node needs nothing beyond
/// the message itself — there is no "fetch" step for a flaky radio to lose.
public struct Handoff: Codable, Sendable, Equatable {
  public let itemID: String
  public let text: String

  public init(itemID: String, text: String) {
    self.itemID = itemID
    self.text = text
  }
}

/// How an execution attempt ended.
public enum WorkOutcome: Codable, Sendable, Equatable {
  /// Issues are carried as rendered descriptions, not structured values: the
  /// coordinator only relays them to the caller and never branches on them,
  /// mirroring how `WrittenDocument.unresolved` leaves judgement to the caller.
  case completed(text: String, issues: [String])
  case failed(reason: String)
}

/// Everything mesh nodes say to each other. Pure data — no networking here.
public enum MeshMessage: Codable, Sendable, Equatable {
  /// Coordinator confirms a join and names the session being worked.
  case announce(session: String, items: Int)
  /// A node asks to participate, advertising what it can execute.
  case join(capabilities: [WorkKind])
  /// Coordinator offers one claimable item, dependencies' outputs attached.
  case offer(item: WorkItem, inputs: [Handoff])
  /// A node accepts an offer. The offer named a single node, so a claim that
  /// matches the standing offer is granted implicitly — no third round trip.
  case claim(itemID: String)
  /// A node reports partial progress; doubles as evidence of liveness.
  case progress(itemID: String, fraction: Double)
  /// A node returns a finished attempt, successful or not.
  case result(itemID: String, outcome: WorkOutcome)
  /// A node gives an item back unexecuted — a capacity signal, not a verdict.
  case release(itemID: String, reason: String)
  /// A node is alive and has nothing else to say.
  case heartbeat
}

/// The unit the transport carries: sender, protocol version, message.
public struct MeshEnvelope: Sendable, Equatable {
  /// Bump on any change to the message vocabulary. Decoding checks this
  /// before touching the body, so a newer peer surfaces as a clean
  /// `unsupportedVersion` instead of an opaque `DecodingError` from whichever
  /// unknown case happened to trip first.
  public static let currentVersion = 1

  public let version: Int
  public let from: NodeID
  public let body: MeshMessage

  public init(from: NodeID, body: MeshMessage) {
    self.version = Self.currentVersion
    self.from = from
    self.body = body
  }
}

extension MeshEnvelope: Codable {
  private enum CodingKeys: String, CodingKey {
    case version, from, body
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else {
      throw MeshProtocolError.unsupportedVersion(version)
    }
    self.version = version
    self.from = try container.decode(NodeID.self, forKey: .from)
    self.body = try container.decode(MeshMessage.self, forKey: .body)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(from, forKey: .from)
    try container.encode(body, forKey: .body)
  }
}

public enum MeshProtocolError: Error, Equatable, CustomStringConvertible {
  case unsupportedVersion(Int)

  public var description: String {
    switch self {
    case .unsupportedVersion(let version):
      return "Envelope speaks protocol version \(version); this build speaks \(MeshEnvelope.currentVersion)."
    }
  }
}
