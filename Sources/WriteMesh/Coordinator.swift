import Foundation

/// Where an item is in its life. Offers carry a deadline too, because an
/// offer lost by the radio would otherwise pin the item forever.
public enum ItemState: Sendable, Equatable {
  case pending
  case offered(to: NodeID, expires: MeshTick)
  case claimed(by: NodeID, expires: MeshTick)
  case done
  case failed(reason: String)

  public var isTerminal: Bool {
    switch self {
    case .done, .failed: return true
    case .pending, .offered, .claimed: return false
    }
  }
}

/// Owns the task graph and decides who works on what.
///
/// Everything time-shaped goes through the injected `now` closure: the
/// coordinator never reads a wall clock, so a test can walk it through lease
/// expiry and node death one tick at a time. `tick()` is the only place time
/// has consequences; the host calls it on whatever cadence the deployment
/// wants.
public actor Coordinator {
  public struct Configuration: Sendable {
    /// Ticks a node holds an item — offered or claimed — before it is taken back.
    public let leaseTicks: Int
    /// Ticks of silence after which a node is presumed gone.
    public let heartbeatTimeoutTicks: Int
    /// Failed execution attempts tolerated before the item is marked failed.
    public let maxAttempts: Int

    public init(leaseTicks: Int = 8, heartbeatTimeoutTicks: Int = 24, maxAttempts: Int = 3) {
      self.leaseTicks = leaseTicks
      self.heartbeatTimeoutTicks = heartbeatTimeoutTicks
      self.maxAttempts = maxAttempts
    }
  }

  private struct NodeRecord {
    var capabilities: Set<WorkKind>
    var lastSeen: MeshTick
    var alive: Bool
    /// The item this node currently holds. One at a time, deliberately: a
    /// phone-class device runs one generation at a time anyway, and a single
    /// slot keeps reassignment on node death trivial to reason about.
    var assignment: String?
  }

  // Nonisolated: immutable identity a caller needs while constructing peers.
  public nonisolated let id: NodeID
  public nonisolated let session: String
  public nonisolated let configuration: Configuration

  private let transport: MeshTransport
  private let now: @Sendable () -> MeshTick

  private let itemsByID: [String: WorkItem]
  /// Graph order, used everywhere a choice must be deterministic.
  private let order: [String]
  private let dependents: [String: [String]]

  private var states: [String: ItemState] = [:]
  private var attempts: [String: Int] = [:]
  /// Nodes to prefer not offering this item to again — they failed it, let
  /// its lease lapse, or handed it back.
  private var avoid: [String: Set<NodeID>] = [:]
  private var texts: [String: String] = [:]
  private var reportedIssues: [String: [String]] = [:]
  private var nodes: [NodeID: NodeRecord] = [:]

  public init(
    graph: TaskGraph,
    transport: MeshTransport,
    configuration: Configuration = Configuration(),
    id: NodeID = NodeID("coordinator"),
    session: String = "33write",
    now: @escaping @Sendable () -> MeshTick
  ) throws {
    // Admission is the last cheap moment to reject a bad graph; a cycle
    // discovered here is an error, discovered later it is a silent hang.
    try graph.validate()
    self.id = id
    self.session = session
    self.configuration = configuration
    self.transport = transport
    self.now = now
    self.itemsByID = Dictionary(uniqueKeysWithValues: graph.items.map { ($0.id, $0) })
    self.order = graph.items.map(\.id)
    var dependents: [String: [String]] = [:]
    for item in graph.items {
      for dependency in item.dependencies {
        dependents[dependency, default: []].append(item.id)
      }
    }
    self.dependents = dependents
    for item in graph.items { states[item.id] = .pending }
  }

  /// Attach to the transport and start accepting joins.
  public func start() async {
    await transport.attach(id) { [weak self] envelope in
      await self?.handle(envelope)
    }
  }

  /// Advance time-driven state: expire leases, presume silent nodes dead,
  /// and re-offer whatever that freed.
  public func tick() async {
    let current = now()

    for (nodeID, record) in nodes where record.alive {
      if current >= record.lastSeen.advanced(by: configuration.heartbeatTimeoutTicks) {
        nodes[nodeID]!.alive = false
        if let itemID = record.assignment { reclaim(itemID, from: nodeID) }
      }
    }
    for itemID in order {
      switch states[itemID]! {
      case .offered(let node, let expires) where current >= expires:
        reclaim(itemID, from: node)
      case .claimed(let node, let expires) where current >= expires:
        reclaim(itemID, from: node)
      default:
        break
      }
    }
    await offerReadyItems()
  }

  // MARK: Observation

  public var isComplete: Bool {
    order.allSatisfy { states[$0]!.isTerminal }
  }

  public func state(of itemID: String) -> ItemState? { states[itemID] }
  public func text(of itemID: String) -> String? { texts[itemID] }
  public func issues(of itemID: String) -> [String] { reportedIssues[itemID] ?? [] }
  public func attemptCount(of itemID: String) -> Int { attempts[itemID] ?? 0 }

  // MARK: Message handling

  private func handle(_ envelope: MeshEnvelope) async {
    let sender = envelope.from
    switch envelope.body {
    case .join(let capabilities):
      nodes[sender] = NodeRecord(
        capabilities: Set(capabilities),
        lastSeen: now(),
        alive: true,
        assignment: nodes[sender]?.assignment
      )
      await send(.announce(session: session, items: order.count), to: sender)
      await offerReadyItems()

    case .claim(let itemID):
      touch(sender)
      // A claim only sticks if it matches the standing offer. Anything else
      // is a stale race — the offer moved on — and is ignored; the claimer's
      // eventual result is still accepted below if the item remains open.
      if case .offered(let node, _) = states[itemID] ?? .pending, node == sender {
        states[itemID] = .claimed(
          by: sender,
          expires: now().advanced(by: configuration.leaseTicks)
        )
      }

    case .progress(_, _):
      // Progress is not tracked per-item yet; its value here is liveness —
      // a node mid-generation must not be presumed dead.
      touch(sender)

    case .result(let itemID, let outcome):
      touch(sender)
      await acceptResult(itemID, outcome: outcome, from: sender)

    case .release(let itemID, _):
      touch(sender)
      switch states[itemID] ?? .pending {
      case .offered(let node, _) where node == sender,
        .claimed(let node, _) where node == sender:
        reclaim(itemID, from: sender)
        await offerReadyItems()
      default:
        break
      }

    case .heartbeat:
      touch(sender)

    case .announce, .offer:
      // Coordinator-to-node vocabulary; a copy arriving here is noise.
      break
    }
  }

  private func acceptResult(_ itemID: String, outcome: WorkOutcome, from sender: NodeID) async {
    if nodes[sender]?.assignment == itemID {
      nodes[sender]!.assignment = nil
    }
    // First result wins. A stale node finishing an item that was reassigned
    // and already completed changes nothing; the text is idempotent.
    guard let state = states[itemID], !state.isTerminal else { return }

    switch outcome {
    case .completed(let text, let issues):
      states[itemID] = .done
      texts[itemID] = text
      reportedIssues[itemID] = issues
    case .failed(let reason):
      attempts[itemID, default: 0] += 1
      avoid[itemID, default: []].insert(sender)
      if attempts[itemID]! >= configuration.maxAttempts {
        fail(itemID, reason: reason)
      } else {
        states[itemID] = .pending
      }
    }
    await offerReadyItems()
  }

  // MARK: Scheduling

  private func offerReadyItems() async {
    for itemID in order {
      guard case .pending = states[itemID]! else { continue }
      let item = itemsByID[itemID]!
      guard item.dependencies.allSatisfy({ states[$0] == .done }) else { continue }
      guard let node = pickNode(for: item) else { continue }

      states[itemID] = .offered(to: node, expires: now().advanced(by: configuration.leaseTicks))
      nodes[node]!.assignment = itemID
      // Dependency outputs ride along in dependency order, so the section
      // texts an assemble item receives are already in document order.
      let inputs = item.dependencies.map { Handoff(itemID: $0, text: texts[$0] ?? "") }
      await send(.offer(item: item, inputs: inputs), to: node)
    }
  }

  private func pickNode(for item: WorkItem) -> NodeID? {
    let capable = nodes.filter { $0.value.alive && $0.value.capabilities.contains(item.kind) }
    let idle = capable.filter { $0.value.assignment == nil }.keys.sorted()
    guard !idle.isEmpty else { return nil }

    let avoided = avoid[item.id] ?? []
    if let fresh = idle.first(where: { !avoided.contains($0) }) { return fresh }
    // Every idle node has history on this item. If a fresh node is merely
    // busy, hold the item for it — a retry on the node that just failed it is
    // likely to fail the same way. Only when no fresh node exists at all does
    // a repeat beat leaving the item stranded.
    let freshExistsSomewhere = capable.keys.contains { !avoided.contains($0) }
    return freshExistsSomewhere ? nil : idle.first
  }

  private func reclaim(_ itemID: String, from node: NodeID) {
    states[itemID] = .pending
    avoid[itemID, default: []].insert(node)
    if nodes[node]?.assignment == itemID {
      nodes[node]!.assignment = nil
    }
  }

  private func fail(_ itemID: String, reason: String) {
    states[itemID] = .failed(reason: reason)
    // Dependents can never become ready, so mark them failed now. Leaving
    // them pending would make completion undetectable; independent branches
    // are untouched and keep running.
    var frontier = dependents[itemID, default: []]
    while let dependent = frontier.popLast() {
      guard !(states[dependent]?.isTerminal ?? true) else { continue }
      states[dependent] = .failed(reason: "dependency '\(itemID)' failed")
      frontier.append(contentsOf: dependents[dependent, default: []])
    }
  }

  private func touch(_ node: NodeID) {
    guard nodes[node] != nil else { return }
    nodes[node]!.lastSeen = now()
    nodes[node]!.alive = true
  }

  private func send(_ body: MeshMessage, to node: NodeID) async {
    await transport.send(MeshEnvelope(from: id, body: body), to: node)
  }
}
