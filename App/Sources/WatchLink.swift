import Foundation
import WatchConnectivity

/// Answers the watch's request for fleet state.
///
/// This exists because the watch cannot reach the fleet from outside its
/// network: an Apple Watch routes through its paired iPhone, so once that
/// phone is off the fleet's LAN the watch's own polling finds nothing. The
/// phone is on the tailnet wherever it is, so it can still answer.
///
/// Tailnet addresses rather than the `.local` names the watch uses directly —
/// mDNS does not cross a network, and answering from the road is the entire
/// reason this path exists.
@MainActor
final class WatchLink: NSObject {
  static let shared = WatchLink()

  nonisolated private static let nodes = [
    "100.73.112.15",    // M5 Max
    "100.101.220.18",   // Mac mini M4 Pro
    "100.67.145.126",   // MacBook Air M3
  ]

  func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    if session.activationState != .activated { session.activate() }
  }

  /// Polls the Macs and sums what they report.
  ///
  /// `throughput` is each node's rolling ten-second aggregate, which is the
  /// only figure here that means what it says — `tokensPerSecond` is one
  /// request's rate, and summing those across a fleet understates it about
  /// fivefold.
  /// A value type, not a dictionary. `[String: Any]` is not Sendable, so it
  /// cannot cross the actor boundary between this survey and the delegate
  /// callback that answers the watch.
  struct Snapshot: Sendable {
    let inFlight: Int
    let throughput: Double
    let nodes: Int

    var payload: [String: Any] {
      ["inFlight": inFlight, "throughput": throughput, "nodes": nodes]
    }
  }

  nonisolated fileprivate static func survey() async -> Snapshot {
    var inFlight = 0
    var throughput = 0.0
    var reachable = 0

    await withTaskGroup(of: (Int, Double)?.self) { group in
      for host in nodes {
        group.addTask {
          guard let url = URL(string: "http://\(host):8833/health") else { return nil }
          var request = URLRequest(url: url)
          request.timeoutInterval = 6
          guard let (data, _) = try? await URLSession.shared.data(for: request),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let capabilities = payload["capabilities"] as? [String: Any]
          else { return nil }
          return (
            capabilities["inFlight"] as? Int ?? 0,
            payload["throughput"] as? Double ?? 0
          )
        }
      }
      for await result in group {
        guard let (flight, rate) = result else { continue }
        reachable += 1
        inFlight += flight
        throughput += rate
      }
    }
    return Snapshot(inFlight: inFlight, throughput: throughput, nodes: reachable)
  }
}

/// Carries WatchConnectivity's reply handler across a task boundary.
///
/// `@unchecked` because the closure is not Sendable and cannot be made so —
/// it comes from the framework. It is safe to move: WatchConnectivity
/// documents the handler as callable from any thread, and this calls it
/// exactly once, on one task, with a value type.
private struct ReplyBox: @unchecked Sendable {
  let send: ([String: Any]) -> Void
}

extension WatchLink: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  nonisolated func session(
    _ session: WCSession, didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard message["ask"] as? String == "fleet" else {
      replyHandler([:])
      return
    }
    // The reply handler has a short window and the survey is network work, so
    // it runs on its own task rather than blocking the delegate callback.
    let box = ReplyBox(send: replyHandler)
    Task {
      let snapshot = await WatchLink.survey()
      box.send(snapshot.payload)
    }
  }
}
