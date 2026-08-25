import Foundation

/// The whole fleet in four numbers.
///
/// Deliberately small and Sendable: this crosses into widget timeline
/// providers, which run in a separate short-lived process with a tight budget.
/// Nothing here holds a connection, a cache, or an observation.
public struct FleetSnapshot: Sendable, Equatable {
  public let throughput: Double
  public let inFlight: Int
  public let reachable: Int
  public let total: Int

  public init(throughput: Double = 0, inFlight: Int = 0, reachable: Int = 0, total: Int = 0) {
    self.throughput = throughput
    self.inFlight = inFlight
    self.reachable = reachable
    self.total = total
  }

  public var working: Bool { inFlight > 0 }
}

/// Reads fleet state without the machinery the apps use.
///
/// `FleetManager` keeps a roster, persists it, auto-refreshes, and publishes
/// observations — all correct for a window someone is looking at, and all
/// wrong for a widget, which gets a few seconds and then is gone.
public enum FleetProbe {
  /// The Macs, by tailnet address.
  ///
  /// Tailnet rather than `.local` because a widget may refresh anywhere, and
  /// mDNS does not cross a network. Macs only: they are ~95% of throughput and
  /// the part that stays up, so polling phones would spend the budget on churn.
  public static let macs = [
    "100.73.112.15",    // M5 Max
    "100.101.220.18",   // Mac mini M4 Pro
    "100.67.145.126",   // MacBook Air M3
  ]

  public static func snapshot(hosts: [String] = macs, timeout: TimeInterval = 4) async -> FleetSnapshot {
    var throughput = 0.0
    var inFlight = 0
    var reachable = 0

    await withTaskGroup(of: (Double, Int)?.self) { group in
      for host in hosts {
        group.addTask {
          guard let url = URL(string: "http://\(host):8833/health") else { return nil }
          var request = URLRequest(url: url)
          request.timeoutInterval = timeout
          request.cachePolicy = .reloadIgnoringLocalCacheData
          guard let (data, _) = try? await URLSession.shared.data(for: request),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
          else { return nil }
          let capabilities = payload["capabilities"] as? [String: Any] ?? [:]
          return (payload["throughput"] as? Double ?? 0, capabilities["inFlight"] as? Int ?? 0)
        }
      }
      for await result in group {
        guard let (rate, flight) = result else { continue }
        reachable += 1
        throughput += rate
        inFlight += flight
      }
    }
    return FleetSnapshot(
      throughput: throughput, inFlight: inFlight, reachable: reachable, total: hosts.count
    )
  }
}
