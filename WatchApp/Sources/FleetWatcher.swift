import Foundation
import Observation
import WatchKit

/// Polls the fleet and drives the display state.
///
/// The watch has no Tailscale, so it cannot reach 100.x addresses. It CAN
/// reach the LAN directly over Wi-Fi, and the Macs publish stable mDNS names —
/// so the permanent nodes are polled by .local hostname, which survives DHCP,
/// plus the phones' last-known LAN addresses as best effort. A node that does
/// not answer simply contributes nothing; the watch is a reader, never a
/// participant, and a missed poll costs a stale frame rather than a task.
@MainActor
@Observable
final class FleetWatcher {
  /// True while any reachable node reports work in flight.
  private(set) var engaged = false
  /// Sum of reachable nodes' current rates, tokens per second.
  private(set) var tokensPerSecond: Double = 0
  private(set) var reachableNodes = 0
  /// When the engaged state last flipped, for easing the colour transition.
  private(set) var transitionedAt = Date.distantPast

  /// Permanent nodes by stable name, burst nodes by last-known LAN address.
  /// The phones' entries are best effort — DHCP can move them — but a wrong
  /// address only mutes their contribution to the total.
  var hosts = [
    "nicholass-macbook-pro-2.local",
    "33io-backend.local",
    "192.168.1.112",  // iPhone 15 Pro Max
    "192.168.1.98",   // iPhone 17 Pro Max
  ]

  private var pollTask: Task<Void, Never>?
  private var tingleTask: Task<Void, Never>?

  func start() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sweep()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func stop() {
    pollTask?.cancel(); pollTask = nil
    tingleTask?.cancel(); tingleTask = nil
  }

  private func sweep() async {
    let hostList = hosts
    var inFlight = 0
    var rate = 0.0
    var reachable = 0

    await withTaskGroup(of: (Int, Double)?.self) { group in
      for host in hostList {
        group.addTask {
          guard let url = URL(string: "http://\(host):8833/health") else { return nil }
          var request = URLRequest(url: url)
          request.timeoutInterval = 3
          guard let (data, _) = try? await URLSession.shared.data(for: request),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let capabilities = payload["capabilities"] as? [String: Any]
          else { return nil }
          return (
            capabilities["inFlight"] as? Int ?? 0,
            capabilities["tokensPerSecond"] as? Double ?? 0
          )
        }
      }
      for await result in group {
        guard let (flight, nodeRate) = result else { continue }
        reachable += 1
        inFlight += flight
        if flight > 0 { rate += nodeRate }
      }
    }

    reachableNodes = reachable
    tokensPerSecond = rate
    setEngaged(inFlight > 0)
  }

  private func setEngaged(_ working: Bool) {
    guard working != engaged else { return }
    engaged = working
    transitionedAt = Date()
    if working {
      WKInterfaceDevice.current().play(.start)
      startTingles()
    } else {
      tingleTask?.cancel(); tingleTask = nil
      WKInterfaceDevice.current().play(.stop)
    }
  }

  /// A soft click every few seconds while the fleet works — enough to feel
  /// without looking, spaced so it stays a pulse rather than a nag.
  private func startTingles() {
    tingleTask?.cancel()
    tingleTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled, self?.engaged == true else { return }
        WKInterfaceDevice.current().play(.click)
      }
    }
  }
}
