import Foundation
import WriteCore

/// The shape of work an item asks for, without its payload.
///
/// Nodes advertise capability in these terms when they join, so the
/// coordinator can route an item without inspecting its payload.
public enum WorkKind: String, Codable, Sendable, CaseIterable {
  case section, review, assemble
}

/// What a node needs to execute an item.
///
/// An enum rather than an opaque blob so the compiler forces every executor to
/// say what it does with each kind — and so new kinds can be added without
/// touching `WorkItem` itself.
public enum WorkPayload: Codable, Sendable, Equatable {
  /// Write one section. The spec is already rehydrated device-side material;
  /// it never travels back to the cloud from here.
  case section(SectionSpec)
  /// Check another item's output. The text arrives as a handoff input.
  case review(targetItemID: String)
  /// Join the outputs of every dependency into one document.
  case assemble
}

/// One schedulable unit of mesh work.
public struct WorkItem: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  /// Item ids that must be `done` before this item may be offered.
  public let dependencies: [String]
  public let payload: WorkPayload

  public init(id: String, dependencies: [String], payload: WorkPayload) {
    self.id = id
    self.dependencies = dependencies
    self.payload = payload
  }

  /// Derived from the payload rather than stored, so the two can never
  /// disagree — a stored kind next to a payload is an invariant waiting to
  /// break in a decoded message.
  public var kind: WorkKind {
    switch payload {
    case .section: return .section
    case .review: return .review
    case .assemble: return .assemble
    }
  }
}

/// A dependency-ordered set of work items.
public struct TaskGraph: Codable, Sendable, Equatable {
  public let items: [WorkItem]

  public init(items: [WorkItem]) {
    self.items = items
  }

  /// Reject a graph the mesh cannot finish, before any item is offered.
  ///
  /// Mirrors `Plan.validate`: a graph that fails here is a construction bug,
  /// and no amount of scheduling would fix it. A cycle in particular would
  /// leave the coordinator waiting forever with every item pending, which is
  /// far harder to diagnose at runtime than at admission.
  public func validate() throws {
    guard !items.isEmpty else { throw TaskGraphError.noItems }

    var seen = Set<String>()
    for item in items {
      guard seen.insert(item.id).inserted else {
        throw TaskGraphError.duplicateItemID(item.id)
      }
    }
    for item in items {
      for dependency in item.dependencies where !seen.contains(dependency) {
        throw TaskGraphError.unknownDependency(item: item.id, dependency: dependency)
      }
    }

    // Kahn's algorithm. Whatever cannot be peeled off is on or behind a
    // cycle; naming those ids beats reporting a bare "cycle detected".
    var indegree: [String: Int] = [:]
    var dependents: [String: [String]] = [:]
    for item in items {
      indegree[item.id] = item.dependencies.count
      for dependency in item.dependencies {
        dependents[dependency, default: []].append(item.id)
      }
    }
    var ready = items.map(\.id).filter { indegree[$0] == 0 }
    var peeled = 0
    while let id = ready.popLast() {
      peeled += 1
      for dependent in dependents[id, default: []] {
        indegree[dependent]! -= 1
        if indegree[dependent] == 0 { ready.append(dependent) }
      }
    }
    if peeled < items.count {
      let stuck = indegree.filter { $0.value > 0 }.keys.sorted()
      throw TaskGraphError.cycle(involving: stuck)
    }
  }
}

extension TaskGraph {
  /// The id given to the assemble item a converted plan ends with.
  public static let assembleItemID = "assemble"

  /// A `Plan` as mesh work: every section in parallel, then one assemble item
  /// depending on all of them.
  ///
  /// This deliberately drops the tail-continuity the single-device pipeline
  /// threads from section to section — that is the price of parallelism. The
  /// assemble step is where coherence is re-established, with every section's
  /// text in hand.
  public static func from(_ plan: Plan) throws -> TaskGraph {
    let sections = plan.sections.map {
      WorkItem(id: $0.id, dependencies: [], payload: .section($0))
    }
    let assemble = WorkItem(
      id: assembleItemID,
      dependencies: plan.sections.map(\.id),
      payload: .assemble
    )
    let graph = TaskGraph(items: sections + [assemble])
    // Catches, among construction bugs, a plan whose section is literally
    // named "assemble" — a collision this conversion cannot express.
    try graph.validate()
    return graph
  }
}

public enum TaskGraphError: Error, Equatable, CustomStringConvertible {
  case noItems
  case duplicateItemID(String)
  case unknownDependency(item: String, dependency: String)
  case cycle(involving: [String])

  public var description: String {
    switch self {
    case .noItems:
      return "Task graph contains no items."
    case .duplicateItemID(let id):
      return "Task graph reuses item id '\(id)'."
    case .unknownDependency(let item, let dependency):
      return "Item '\(item)' depends on '\(dependency)', which is not in the graph."
    case .cycle(let involving):
      return "Task graph has a dependency cycle involving: \(involving.joined(separator: ", "))."
    }
  }
}
