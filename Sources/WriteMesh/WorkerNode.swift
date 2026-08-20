import Foundation

/// Executes one work item. On a real device this is backed by the
/// `DeviceWriter`; tests inject stubs.
///
/// The executor sees the item and its dependency handoffs, nothing about the
/// mesh — so the same executor runs identically whether the item arrived over
/// a radio or from an in-process test.
public protocol WorkExecutor: Sendable {
  func execute(_ item: WorkItem, inputs: [Handoff]) async throws -> WorkOutput
}

/// What an executor hands back: the text, plus whatever the local verifier
/// flagged. Issues travel as rendered descriptions because nobody upstream
/// branches on them — the caller at the coordinator decides, as with
/// `WrittenDocument.unresolved`.
public struct WorkOutput: Sendable, Equatable {
  public let text: String
  public let issues: [String]

  public init(text: String, issues: [String] = []) {
    self.text = text
    self.issues = issues
  }
}

/// One device's presence in the mesh: claims what it can execute, runs it,
/// reports back.
///
/// The worker claims and then executes without waiting for a grant. The offer
/// already named this node exclusively, so the claim is confirmation, not a
/// request — and if the claim is lost in transit, the coordinator still
/// accepts the result while the item is open. Wasted work on a true race
/// costs one generation; a grant round-trip would cost one per item, always.
public actor WorkerNode {
  public nonisolated let id: NodeID
  private let coordinator: NodeID
  private let transport: MeshTransport
  private let executor: WorkExecutor
  private let capabilities: Set<WorkKind>

  public init(
    id: NodeID,
    coordinator: NodeID,
    transport: MeshTransport,
    executor: WorkExecutor,
    capabilities: Set<WorkKind> = Set(WorkKind.allCases)
  ) {
    self.id = id
    self.coordinator = coordinator
    self.transport = transport
    self.executor = executor
    self.capabilities = capabilities
  }

  /// Attach to the transport and ask to participate.
  public func join() async {
    await transport.attach(id) { [weak self] envelope in
      await self?.handle(envelope)
    }
    // Sorted so the same node always says the same thing on the wire.
    await send(.join(capabilities: capabilities.sorted { $0.rawValue < $1.rawValue }))
  }

  /// Tell the coordinator this node is still here. The host calls this on its
  /// own cadence; the worker owns no timer, which keeps it deterministic.
  public func beat() async {
    await send(.heartbeat)
  }

  private func handle(_ envelope: MeshEnvelope) async {
    guard envelope.from == coordinator else { return }
    guard case .offer(let item, let inputs) = envelope.body else { return }

    // The coordinator routes by advertised capability, so this is a defence
    // against a stale or misdirected offer, not the normal path.
    guard capabilities.contains(item.kind) else {
      await send(.release(itemID: item.id, reason: "kind '\(item.kind.rawValue)' unsupported"))
      return
    }

    await send(.claim(itemID: item.id))
    // Progress at zero marks the start of a generation that may outlast a
    // heartbeat interval — it keeps the lease's owner visibly alive.
    await send(.progress(itemID: item.id, fraction: 0))
    do {
      let output = try await executor.execute(item, inputs: inputs)
      await send(.result(itemID: item.id, outcome: .completed(text: output.text, issues: output.issues)))
    } catch {
      await send(.result(itemID: item.id, outcome: .failed(reason: String(describing: error))))
    }
  }

  private func send(_ body: MeshMessage) async {
    await transport.send(MeshEnvelope(from: id, body: body), to: coordinator)
  }
}
