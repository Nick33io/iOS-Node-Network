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
  /// True when this reading came from the phone rather than the watch's own
  /// polling, so the display can say which it is.
  private(set) var viaPhone = false

  /// The three Macs, by mDNS name.
  ///
  /// Names rather than addresses because DHCP moves the addresses: the two
  /// phone entries that used to be here — 192.168.1.112 and .98 — were both
  /// stale, so the watch was polling nothing and would have shown an idle
  /// fleet however hard the fleet was working. The Mac mini was missing
  /// outright.
  ///
  /// Only Macs. The phones were measured at roughly 5% of fleet throughput and
  /// they do not survive sustained load — iOS suspends or kills the node app —
  /// so including them adds churn to the reading without adding signal. This
  /// display answers "is the fleet working", and the Macs are the fleet.
  /// Both forms for each Mac: the mDNS name survives a DHCP lease change, the
  /// raw address survives mDNS not resolving. A watch reaches the network
  /// through its paired iPhone over Bluetooth, and `.local` lookups across that
  /// link are slow enough to be unreliable — so neither form alone is safe, and
  /// a duplicate hit costs one extra request every two seconds.
  var hosts = [
    "Nicholass-MacBook-Pro-2.local", "192.168.1.218",  // M5 Max
    "NicX-Mini.local", "192.168.1.196",                // Mac mini M4 Pro
    "33io-backend.local", "192.168.1.117",             // MacBook Air M3
  ]

  private var pollTask: Task<Void, Never>?
  private var tingleTask: Task<Void, Never>?

  func start() {
    guard pollTask == nil else { return }
    PhoneLink.shared.activate()
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
          // 3s was too tight. The request leaves the watch, crosses Bluetooth
          // to the phone, then the LAN — and if the host is an mDNS name the
          // lookup happens over that same hop. Every probe timed out and the
          // display sat at "no fleet" through a fully loaded fleet.
          request.timeoutInterval = 8
          guard let (data, _) = try? await URLSession.shared.data(for: request),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let capabilities = payload["capabilities"] as? [String: Any]
          else { return nil }
          // `throughput` is the node's rolling 10s aggregate; the older
          // `tokensPerSecond` is one request's rate and summing those across a
          // fleet understated it fivefold — the wrist read 73 tok/s while the
          // fleet was measured at 400.
          let payloadRate = (payload["throughput"] as? Double)
            ?? (capabilities["tokensPerSecond"] as? Double ?? 0)
          return (capabilities["inFlight"] as? Int ?? 0, payloadRate)
        }
      }
      for await result in group {
        guard let (flight, nodeRate) = result else { continue }
        reachable += 1
        inFlight += flight
        rate += nodeRate
      }
    }

    // Direct polling is primary and only falls back when it finds nothing at
    // all. The Macs are the reliable part of this fleet; the phone is not —
    // iOS suspends and kills the node app under exactly the sustained load
    // worth watching — so the phone answers for the case direct cannot cover,
    // being off the fleet's network, rather than standing in front of it.
    if reachable == 0, let relayed = await PhoneLink.shared.fleet() {
      reachable = relayed.nodes
      inFlight = relayed.inFlight
      rate = relayed.throughput
      viaPhone = reachable > 0
    } else {
      viaPhone = false
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
