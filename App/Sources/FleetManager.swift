import Foundation
import Observation
import NodeKit

/// One node as the manager currently understands it.
struct FleetNode: Identifiable, Sendable {
  enum State: Sendable, Equatable {
    case unknown
    case reachable
    /// Answered, but is not currently able to take work.
    case idle
    case unreachable(String)
  }

  let id: String
  var label: String
  var host: String
  var state: State = .unknown
  var hardware: String?
  var model: String?
  var backend: String?
  var thermal: String?
  var power: String?
  var memoryGiB: Double?
  var suitedToLongWork: Bool?
  /// Last measured throughput. Nil until this node has been benchmarked —
  /// deliberately not defaulted to zero, which would read as "measured and slow"
  /// rather than "never measured".
  var tokensPerSecond: Double?
  var lastProbe: Date?
  var probeMilliseconds: Int?

  var isReachable: Bool {
    if case .reachable = state { return true }
    if case .idle = state { return true }
    return false
  }
}

/// The iPad's view of the fleet.
///
/// A manager cannot wake a sleeping node: iOS suspends a backgrounded app and
/// nothing on the network can revive it. So "on/off" here means the node's
/// listener, which is the only part a reachable node can be told to change.
/// Presenting a power switch that silently fails on a suspended device would be
/// worse than not offering one.
@MainActor
@Observable
final class FleetManager {
  var nodes: [FleetNode] = []
  var isRefreshing = false
  var lastSweep: Date?

  private static let rosterKey = "fleet.roster.v1"

  init() {
    nodes = Self.loadRoster()
  }

  // MARK: Roster

  /// Seeded with the tailnet addresses this fleet already uses. Editable,
  /// because addresses outlive any hardcoded list.
  static let defaultRoster: [(String, String)] = [
    ("M5 Max", "100.73.112.15"),
    ("Mini M4 Pro", "100.101.220.18"),
    ("iPhone 15 Pro Max", "100.126.56.73"),
    ("iPhone 17 Pro Max", "100.65.9.108"),
  ]

  private static func loadRoster() -> [FleetNode] {
    if let stored = UserDefaults.standard.array(forKey: rosterKey) as? [[String: String]],
      !stored.isEmpty
    {
      return stored.compactMap { entry in
        guard let label = entry["label"], let host = entry["host"] else { return nil }
        return FleetNode(id: host, label: label, host: host)
      }
    }
    return defaultRoster.map { FleetNode(id: $0.1, label: $0.0, host: $0.1) }
  }

  private func saveRoster() {
    let encoded = nodes.map { ["label": $0.label, "host": $0.host] }
    UserDefaults.standard.set(encoded, forKey: Self.rosterKey)
  }

  func add(label: String, host: String) {
    guard !host.isEmpty, !nodes.contains(where: { $0.host == host }) else { return }
    nodes.append(FleetNode(id: host, label: label.isEmpty ? host : label, host: host))
    saveRoster()
  }

  /// Puts back any default node that has been removed.
  ///
  /// Removal is easy and permanent; without this, dropping a node means
  /// retyping a tailnet address from memory to get it back.
  func restoreDefaults() {
    for (label, host) in Self.defaultRoster where !nodes.contains(where: { $0.host == host }) {
      nodes.append(FleetNode(id: host, label: label, host: host))
    }
    nodes.sort { $0.label < $1.label }
    saveRoster()
  }

  func remove(_ node: FleetNode) {
    nodes.removeAll { $0.id == node.id }
    saveRoster()
  }

  // MARK: Probing

  /// Refreshes every node concurrently. Sequential probing would make one
  /// unreachable node delay the whole sweep by its full timeout.
  func refreshAll() async {
    isRefreshing = true
    defer {
      isRefreshing = false
      lastSweep = Date()
    }
    await withTaskGroup(of: (String, FleetNode).self) { group in
      for node in nodes {
        group.addTask { (node.id, await Self.probe(node)) }
      }
      for await (id, updated) in group {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
          // Preserve any measurement already taken; a probe reports presence,
          // not speed.
          let existing = nodes[index].tokensPerSecond
          nodes[index] = updated
          nodes[index].tokensPerSecond = updated.tokensPerSecond ?? existing
        }
      }
    }
  }

  func refresh(_ node: FleetNode) async {
    guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
    let existing = nodes[index].tokensPerSecond
    var updated = await Self.probe(node)
    updated.tokensPerSecond = updated.tokensPerSecond ?? existing
    nodes[index] = updated
  }

  private static func probe(_ node: FleetNode) async -> FleetNode {
    var updated = node
    updated.lastProbe = Date()
    guard let url = URL(string: "http://\(node.host):8833/health") else {
      updated.state = .unreachable("bad address")
      return updated
    }
    var request = URLRequest(url: url)
    // Short: a node that cannot answer a health check in four seconds is not
    // one the scheduler should be handing work to anyway.
    request.timeoutInterval = 4

    let started = Date()
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      updated.probeMilliseconds = Int(-started.timeIntervalSinceNow * 1000)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        updated.state = .unreachable("bad response")
        return updated
      }
      let capabilities = payload["capabilities"] as? [String: Any] ?? [:]
      let profile = payload["profile"] as? [String: Any] ?? [:]
      updated.hardware = capabilities["hardware"] as? String
      updated.model = capabilities["model"] as? String
      updated.backend = capabilities["backend"] as? String
      updated.thermal = capabilities["thermal"] as? String
      updated.power = capabilities["power"] as? String
      updated.suitedToLongWork = capabilities["suitedToLongWork"] as? Bool
      updated.memoryGiB = profile["memoryGiB"] as? Double
      if let label = profile["label"] as? String, !label.isEmpty, label != "iPhone" {
        updated.label = label
      }
      updated.state = updated.suitedToLongWork == false ? .idle : .reachable
      return updated
    } catch {
      updated.probeMilliseconds = nil
      // The common case by far is a suspended iOS app, so say that rather than
      // surfacing a URLSession error code the reader has to decode.
      let reason = (error as NSError).code == NSURLErrorTimedOut ? "asleep" : "offline"
      updated.state = .unreachable(reason)
      return updated
    }
  }

  // MARK: Measuring

  /// Times one short generation. This is the only way to learn a node's speed;
  /// `/health` reports what a node *is*, not what it can currently do.
  func measure(_ node: FleetNode) async {
    guard let index = nodes.firstIndex(where: { $0.id == node.id }),
      let url = URL(string: "http://\(node.host):8833/generate")
    else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.timeoutInterval = 120
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "prompt": "Write one paragraph about why a shoot day runs long. Plain prose.",
      "maxOutputTokens": 256,
    ])

    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rate = payload["tokensPerSecond"] as? Double,
        (payload["characters"] as? Int ?? 0) > 0
      else {
        // A node that answers with no text is not fast, it is broken. Leaving
        // the previous measurement would misreport it as healthy.
        nodes[index].tokensPerSecond = nil
        nodes[index].state = .unreachable("empty response")
        return
      }
      nodes[index].tokensPerSecond = rate
      nodes[index].state = .reachable
    } catch {
      nodes[index].tokensPerSecond = nil
      nodes[index].state = .unreachable("measure failed")
    }
  }

  func measureAll() async {
    for node in nodes where node.isReachable {
      await measure(node)
    }
  }

  /// Sum of measured throughput. Only counts nodes actually measured, so it
  /// reads as fleet capacity rather than an average diluted by unknowns.
  var aggregateTokensPerSecond: Double {
    nodes.compactMap(\.tokensPerSecond).reduce(0, +)
  }

  var reachableCount: Int { nodes.filter(\.isReachable).count }
}
