import Foundation

/// Moves envelopes between node ids. Nothing more.
///
/// `send` does not throw and does not confirm delivery: a wireless mesh
/// cannot promise either, so loss is expressed as silence and recovery lives
/// in one place — the coordinator's lease machinery — rather than being
/// half-duplicated in every caller's error handling. The MultipeerConnectivity
/// adapter conforms to this on Apple platforms; it does not live in this
/// target.
public protocol MeshTransport: Sendable {
  /// Register the handler that receives envelopes addressed to `node`.
  func attach(_ node: NodeID, handler: @escaping @Sendable (MeshEnvelope) async -> Void) async
  /// Fire-and-forget delivery toward `node`.
  func send(_ envelope: MeshEnvelope, to node: NodeID) async
}

/// In-process transport for tests.
///
/// `send` only enqueues; nothing is handled until `drain()` runs the queue.
/// Decoupling delivery from sending is what makes the tests deterministic:
/// messages interleave breadth-first in a fixed order instead of recursing
/// depth-first through whichever node answered fastest, which is also how a
/// real radio behaves — a send returns long before the peer acts on it.
public actor InMemoryTransport: MeshTransport {
  /// One send as observed at the transport, whether or not it was delivered.
  public struct Sent: Sendable {
    public let envelope: MeshEnvelope
    public let to: NodeID
  }

  /// Fault-injection hook: return `true` to act on this envelope.
  public typealias Rule = @Sendable (MeshEnvelope, NodeID) -> Bool

  private var handlers: [NodeID: @Sendable (MeshEnvelope) async -> Void] = [:]
  private var queue: [Sent] = []
  private var held: [Sent] = []
  private var log: [Sent] = []
  private var dropRule: Rule = { _, _ in false }
  private var delayRule: Rule = { _, _ in false }

  public init() {}

  public func attach(
    _ node: NodeID,
    handler: @escaping @Sendable (MeshEnvelope) async -> Void
  ) {
    handlers[node] = handler
  }

  public func send(_ envelope: MeshEnvelope, to node: NodeID) {
    let sent = Sent(envelope: envelope, to: node)
    // Logged before the rules run, so a test can assert on what was attempted
    // even when injection swallowed it.
    log.append(sent)
    if dropRule(envelope, node) { return }
    if delayRule(envelope, node) {
      held.append(sent)
      return
    }
    queue.append(sent)
  }

  /// Deliver queued envelopes until the mesh goes quiet.
  ///
  /// Handlers enqueue further sends while this loop runs; the loop keeps
  /// going until nothing is left, so one call carries a whole exchange to its
  /// natural rest. Envelopes to unattached nodes are dropped silently — that
  /// is a radio talking to a peer that left.
  public func drain() async {
    while !queue.isEmpty {
      let next = queue.removeFirst()
      guard let handler = handlers[next.to] else { continue }
      await handler(next.envelope)
    }
  }

  /// Move every delayed envelope into the live queue, in send order.
  public func releaseHeld() {
    queue.append(contentsOf: held)
    held.removeAll()
  }

  /// Every send observed so far, dropped and delayed ones included.
  public func sent() -> [Sent] { log }

  public func setDropRule(_ rule: @escaping Rule) { dropRule = rule }
  public func setDelayRule(_ rule: @escaping Rule) { delayRule = rule }
}
