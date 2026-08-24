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
  /// Resident footprint on that node, when it reports one.
  var footprintGiB: Double?
  /// Headroom before the OS kills that node's process.
  var availableGiB: Double?
  /// Permanent or burst. Reported by the node, not chosen here.
  var tier: NodeTier?
  var suitedToLongWork: Bool?
  /// Last measured throughput. Nil until this node has been benchmarked —
  /// deliberately not defaulted to zero, which would read as "measured and slow"
  /// rather than "never measured".
  var tokensPerSecond: Double?
  var lastProbe: Date?
  var probeMilliseconds: Int?
  /// Identifies the machine behind the address.
  ///
  /// Several roster entries can answer from one host — a stale address, an
  /// alias, a routing quirk. Without this they all adopt that machine's
  /// reported label after a probe and the list reads as duplicates, while the
  /// fleet silently counts one device as several.
  var fingerprint: String?
  /// Set when another entry already claimed this machine.
  var aliasOf: String?
  /// The underlying failure, verbatim. A summarised reason ("asleep") is a
  /// guess, and a wrong guess sends you looking at the wrong device — so keep
  /// what the network actually said.
  var failureDetail: String?
  /// Link measurement, distinct from generation throughput. A node can be fast
  /// at producing tokens and slow to reach.
  var link: LinkResult?
  var isTestingLink = false

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
  /// Seeded from the tailnet catalogue, so a fresh install already knows the
  /// fleet and nothing has to be typed to get started.
  static var defaultRoster: [(String, String)] {
    KnownNodes.all
      .filter { $0.platform != "Android" || $0.label.contains("Fold") }
      .map { ($0.label, $0.host) }
  }

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
    markAliases()
  }

  /// Flags entries that turned out to be the same machine as an earlier one.
  ///
  /// Kept rather than deleted: the address is still in the roster for a reason,
  /// and silently removing it would look like the app losing nodes. Marking it
  /// says what is actually true — two names, one device.
  private func markAliases() {
    var claimed: [String: String] = [:]
    for index in nodes.indices {
      nodes[index].aliasOf = nil
      guard let fingerprint = nodes[index].fingerprint, !fingerprint.isEmpty,
        nodes[index].isReachable
      else { continue }
      if let owner = claimed[fingerprint], owner != nodes[index].id {
        nodes[index].aliasOf = owner
      } else {
        claimed[fingerprint] = nodes[index].id
      }
    }
  }

  func refresh(_ node: FleetNode) async {
    guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
    let existing = nodes[index].tokensPerSecond
    var updated = await Self.probe(node)
    updated.tokensPerSecond = updated.tokensPerSecond ?? existing
    nodes[index] = updated
    markAliases()
  }

  private static func probe(_ node: FleetNode) async -> FleetNode {
    var updated = node
    updated.lastProbe = Date()
    guard let url = URL(string: "http://\(node.host):8833/health") else {
      updated.state = .unreachable("bad address")
      return updated
    }
    updated.failureDetail = nil
    var request = URLRequest(url: url)
    // Generous on purpose. Four seconds was enough for a warm direct path and
    // not for a cold one: the first connection to an idle Tailscale peer has
    // to complete NAT traversal or fall back to a relay, and on a phone the
    // app may also be waking. The short timeout reported those nodes as
    // offline, which is indistinguishable from a genuinely sleeping device.
    request.timeoutInterval = 12
    request.cachePolicy = .reloadIgnoringLocalCacheData

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
      updated.fingerprint = profile["fingerprint"] as? String
      updated.hardware = capabilities["hardware"] as? String
      updated.model = capabilities["model"] as? String
      updated.backend = capabilities["backend"] as? String
      updated.thermal = capabilities["thermal"] as? String
      updated.power = capabilities["power"] as? String
      updated.suitedToLongWork = capabilities["suitedToLongWork"] as? Bool
      updated.memoryGiB = profile["memoryGiB"] as? Double
      updated.footprintGiB = capabilities["footprintGiB"] as? Double
      updated.availableGiB = capabilities["availableGiB"] as? Double
      updated.tier = (capabilities["tier"] as? String).flatMap(NodeTier.init(rawValue:))
      if let label = profile["label"] as? String, !label.isEmpty, label != "iPhone" {
        updated.label = label
      }
      updated.state = updated.suitedToLongWork == false ? .idle : .reachable
      return updated
    } catch {
      updated.probeMilliseconds = nil
      let failure = error as NSError
      updated.failureDetail = "\(failure.domain) \(failure.code): \(failure.localizedDescription)"
      // A short label for the card, with the verbatim error kept alongside so
      // a wrong guess here does not send anyone to the wrong device.
      let reason: String
      switch failure.code {
      case NSURLErrorTimedOut: reason = "no answer"
      case NSURLErrorCannotConnectToHost: reason = "refused"
      case NSURLErrorNotConnectedToInternet: reason = "no network"
      case NSURLErrorAppTransportSecurityRequiresSecureConnection: reason = "blocked by ATS"
      case NSURLErrorNetworkConnectionLost: reason = "connection lost"
      default: reason = "offline"
      }
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

  /// Measures the network link to one node.
  func testLink(_ node: FleetNode) async {
    guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
    nodes[index].isTestingLink = true
    defer { if let i = nodes.firstIndex(where: { $0.id == node.id }) { nodes[i].isTestingLink = false } }
    do {
      let result = try await LinkTest.run(host: node.host)
      if let i = nodes.firstIndex(where: { $0.id == node.id }) {
        nodes[i].link = result
        nodes[i].failureDetail = nil
      }
    } catch {
      if let i = nodes.firstIndex(where: { $0.id == node.id }) {
        nodes[i].link = nil
        nodes[i].failureDetail = "link test: \((error as NSError).localizedDescription)"
      }
    }
  }

  /// Sequentially, not concurrently: parallel transfers would contend for the
  /// same uplink and each would report a fraction of the real bandwidth.
  func testAllLinks() async {
    for node in nodes where node.isReachable && node.aliasOf == nil {
      await testLink(node)
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
    nodes.filter { $0.aliasOf == nil }.compactMap(\.tokensPerSecond).reduce(0, +)
  }

  /// Distinct machines that are up. An alias must not inflate the count — the
  /// whole point of the fleet view is knowing how much hardware is actually
  /// available.
  var reachableCount: Int { nodes.filter { $0.isReachable && $0.aliasOf == nil }.count }

  /// Grouped for display and for scheduling.
  ///
  /// A node whose tier is unknown is grouped with burst: assuming a node is
  /// permanent when it might not be is the expensive direction of the mistake.
  func nodes(in tier: NodeTier) -> [FleetNode] {
    nodes.filter { node in
      guard node.aliasOf == nil else { return false }
      return (node.tier ?? .burst) == tier
    }
  }

  var permanentUp: Int { nodes(in: .permanent).filter(\.isReachable).count }
  var burstUp: Int { nodes(in: .burst).filter(\.isReachable).count }
}
