import Foundation
import XCTest
import WriteCore
@testable import WriteMesh

/// A clock the test advances by hand. All determinism flows from this: the
/// coordinator sees time move only when a test says so.
private final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = MeshTick(0)

  var now: @Sendable () -> MeshTick {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      return current
    }
  }

  func advance(by ticks: Int) {
    lock.lock()
    current = current.advanced(by: ticks)
    lock.unlock()
  }
}

/// Records which node executed which item, in global order.
private final class ExecutionLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [(node: NodeID, item: String)] = []

  func record(_ node: NodeID, _ item: String) {
    lock.lock()
    entries.append((node, item))
    lock.unlock()
  }

  var all: [(node: NodeID, item: String)] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  func items(executedBy node: NodeID) -> [String] {
    all.filter { $0.node == node }.map(\.item)
  }

  func nodes(thatExecuted item: String) -> [NodeID] {
    all.filter { $0.item == item }.map(\.node)
  }
}

private struct ExecutionRefused: Error, CustomStringConvertible {
  let item: String
  var description: String { "execution of '\(item)' refused" }
}

/// Deterministic stand-in for the device writer: canned text per item,
/// scripted failures by item id.
private struct ScriptedExecutor: WorkExecutor {
  let node: NodeID
  let log: ExecutionLog
  var failing: Set<String> = []

  func execute(_ item: WorkItem, inputs: [Handoff]) async throws -> WorkOutput {
    log.record(node, item.id)
    if failing.contains(item.id) { throw ExecutionRefused(item: item.id) }
    switch item.payload {
    case .section:
      return WorkOutput(text: "text(\(item.id))")
    case .review(let targetItemID):
      return WorkOutput(text: "review(\(targetItemID))")
    case .assemble:
      return WorkOutput(text: inputs.map(\.text).joined(separator: "\n\n"))
    }
  }
}

final class MeshLifecycleTests: XCTestCase {
  private func sectionPlan(_ count: Int) -> Plan {
    Plan(
      title: "T", audience: "a", tone: "plain",
      sections: (1...count).map { index in
        SectionSpec(
          id: "s\(index)", heading: "H\(index)", intent: "i",
          points: [], mustInclude: [], targetWords: 80
        )
      }
    )
  }

  func testFourWorkersCompleteSixSectionsInParallelAndAssembleRunsLast() async throws {
    let clock = ManualClock()
    let transport = InMemoryTransport()
    let log = ExecutionLog()
    let graph = try TaskGraph.from(sectionPlan(6))
    let coordinator = try Coordinator(graph: graph, transport: transport, now: clock.now)
    await coordinator.start()

    let workerIDs: [NodeID] = ["w1", "w2", "w3", "w4"]
    // The transport holds workers weakly (a real radio does not keep its
    // peers alive either), so the test owns them for the duration.
    var workers: [WorkerNode] = []
    for workerID in workerIDs {
      let worker = WorkerNode(
        id: workerID, coordinator: coordinator.id, transport: transport,
        executor: ScriptedExecutor(node: workerID, log: log)
      )
      workers.append(worker)
      await worker.join()
    }
    await transport.drain()

    let complete = await coordinator.isComplete
    XCTAssertTrue(complete)

    // Every worker carried part of the load — the six sections spread across
    // all four nodes rather than serialising onto the first joiner.
    for workerID in workerIDs {
      XCTAssertFalse(log.items(executedBy: workerID).isEmpty, "\(workerID) sat idle")
    }

    // Assemble ran exactly once, after every section.
    XCTAssertEqual(log.all.last?.item, TaskGraph.assembleItemID)
    XCTAssertEqual(log.nodes(thatExecuted: TaskGraph.assembleItemID).count, 1)

    // The handoffs arrived in graph order, so the document reads s1...s6.
    let assembled = await coordinator.text(of: TaskGraph.assembleItemID)
    XCTAssertEqual(assembled, (1...6).map { "text(s\($0))" }.joined(separator: "\n\n"))
    for index in 1...6 {
      let state = await coordinator.state(of: "s\(index)")
      XCTAssertEqual(state, .done)
    }
  }

  func testSilentNodeLeaseExpiresAndItemCompletesElsewhere() async throws {
    let clock = ManualClock()
    let transport = InMemoryTransport()
    let log = ExecutionLog()
    let graph = try TaskGraph.from(sectionPlan(2))
    let configuration = Coordinator.Configuration(leaseTicks: 8, heartbeatTimeoutTicks: 24)
    let coordinator = try Coordinator(
      graph: graph, transport: transport, configuration: configuration, now: clock.now
    )
    await coordinator.start()

    let worker1 = WorkerNode(
      id: "w1", coordinator: coordinator.id, transport: transport,
      executor: ScriptedExecutor(node: "w1", log: log)
    )
    let worker2 = WorkerNode(
      id: "w2", coordinator: coordinator.id, transport: transport,
      executor: ScriptedExecutor(node: "w2", log: log)
    )
    // w2 claims s2, then falls silent: its result never arrives. The claim
    // itself got through, so the coordinator believes the item is being
    // worked until the lease says otherwise.
    await transport.setDropRule { envelope, _ in
      if case .result = envelope.body { return envelope.from == NodeID("w2") }
      return false
    }
    await worker1.join()
    await worker2.join()
    await transport.drain()

    var complete = await coordinator.isComplete
    XCTAssertFalse(complete)
    guard case .claimed(let by, _) = await coordinator.state(of: "s2") else {
      return XCTFail("s2 should be held under w2's claim")
    }
    XCTAssertEqual(by, NodeID("w2"))

    // Time passes; w1 stays chatty, w2 says nothing. The lease lapses and
    // the item goes to the other node.
    clock.advance(by: 8)
    await worker1.beat()
    await transport.drain()
    await coordinator.tick()
    await transport.drain()

    complete = await coordinator.isComplete
    XCTAssertTrue(complete)
    XCTAssertEqual(log.nodes(thatExecuted: "s2"), [NodeID("w2"), NodeID("w1")])
    let text = await coordinator.text(of: "s2")
    XCTAssertEqual(text, "text(s2)")
  }

  func testFailedItemIsRetriedOnADifferentNode() async throws {
    let clock = ManualClock()
    let transport = InMemoryTransport()
    let log = ExecutionLog()
    let graph = try TaskGraph.from(sectionPlan(1))
    let coordinator = try Coordinator(graph: graph, transport: transport, now: clock.now)
    await coordinator.start()

    let worker1 = WorkerNode(
      id: "w1", coordinator: coordinator.id, transport: transport,
      executor: ScriptedExecutor(node: "w1", log: log, failing: ["s1"])
    )
    let worker2 = WorkerNode(
      id: "w2", coordinator: coordinator.id, transport: transport,
      executor: ScriptedExecutor(node: "w2", log: log)
    )
    await worker1.join()
    await worker2.join()
    await transport.drain()

    let complete = await coordinator.isComplete
    XCTAssertTrue(complete)
    // The item went to w1 first, failed there, and was not handed back to
    // the node that just failed it.
    XCTAssertEqual(log.nodes(thatExecuted: "s1"), [NodeID("w1"), NodeID("w2")])
    let attempts = await coordinator.attemptCount(of: "s1")
    XCTAssertEqual(attempts, 1)
    let state = await coordinator.state(of: "s1")
    XCTAssertEqual(state, .done)
  }

  func testExhaustedRetriesMarkFailedWithoutBlockingIndependentItems() async throws {
    let clock = ManualClock()
    let transport = InMemoryTransport()
    let log = ExecutionLog()
    let graph = try TaskGraph.from(sectionPlan(2))
    let configuration = Coordinator.Configuration(maxAttempts: 2)
    let coordinator = try Coordinator(
      graph: graph, transport: transport, configuration: configuration, now: clock.now
    )
    await coordinator.start()

    // Every node refuses s1; the mesh must give up on it after two attempts
    // and still deliver everything that never depended on it.
    var workers: [WorkerNode] = []
    for workerID in [NodeID("w1"), NodeID("w2")] {
      let worker = WorkerNode(
        id: workerID, coordinator: coordinator.id, transport: transport,
        executor: ScriptedExecutor(node: workerID, log: log, failing: ["s1"])
      )
      workers.append(worker)
      await worker.join()
    }
    await transport.drain()

    let complete = await coordinator.isComplete
    XCTAssertTrue(complete)
    XCTAssertEqual(log.nodes(thatExecuted: "s1"), [NodeID("w1"), NodeID("w2")])

    guard case .failed = await coordinator.state(of: "s1") else {
      return XCTFail("s1 should be failed after exhausting attempts")
    }
    // Assemble depends on s1, so it can never run — it fails rather than
    // pinning the graph open forever.
    guard case .failed = await coordinator.state(of: TaskGraph.assembleItemID) else {
      return XCTFail("assemble should fail once a dependency is unrecoverable")
    }
    // The independent section was unaffected.
    let s2 = await coordinator.state(of: "s2")
    XCTAssertEqual(s2, .done)
  }

  func testAnItemIsNeverOfferedBeforeItsDependenciesAreDone() async throws {
    let clock = ManualClock()
    let transport = InMemoryTransport()
    let log = ExecutionLog()
    // Deeper than the plan shape: a review hangs off s1, and assemble waits
    // on everything, so ordering violations have more chances to appear.
    let spec = { (id: String) in
      SectionSpec(id: id, heading: "H", intent: "i", points: [], mustInclude: [], targetWords: 80)
    }
    let graph = TaskGraph(items: [
      WorkItem(id: "s1", dependencies: [], payload: .section(spec("s1"))),
      WorkItem(id: "s2", dependencies: [], payload: .section(spec("s2"))),
      WorkItem(id: "s3", dependencies: [], payload: .section(spec("s3"))),
      WorkItem(id: "r1", dependencies: ["s1"], payload: .review(targetItemID: "s1")),
      WorkItem(id: "assemble", dependencies: ["s1", "s2", "s3", "r1"], payload: .assemble),
    ])
    let coordinator = try Coordinator(graph: graph, transport: transport, now: clock.now)
    await coordinator.start()

    var workers: [WorkerNode] = []
    for workerID in [NodeID("w1"), NodeID("w2")] {
      let worker = WorkerNode(
        id: workerID, coordinator: coordinator.id, transport: transport,
        executor: ScriptedExecutor(node: workerID, log: log)
      )
      workers.append(worker)
      await worker.join()
    }
    await transport.drain()

    let complete = await coordinator.isComplete
    XCTAssertTrue(complete)

    // Replay the wire: at the moment each offer was sent, every dependency
    // must already have had a completed result on the log.
    var done = Set<String>()
    for sent in await transport.sent() {
      switch sent.envelope.body {
      case .offer(let item, let inputs):
        XCTAssertTrue(
          Set(item.dependencies).isSubset(of: done),
          "'\(item.id)' was offered before dependencies \(item.dependencies) were done"
        )
        XCTAssertEqual(inputs.map(\.itemID), item.dependencies)
      case .result(let itemID, .completed):
        done.insert(itemID)
      default:
        break
      }
    }
    XCTAssertEqual(done.count, graph.items.count)
  }
}
