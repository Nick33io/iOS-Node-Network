import Foundation
import WatchConnectivity

/// Asks the paired iPhone for fleet state when the watch cannot reach the
/// fleet itself.
///
/// The watch has no independent route to the LAN — every request it makes
/// crosses Bluetooth to the phone first — so once the watch is away from the
/// fleet's network, direct polling returns nothing at all. The phone can still
/// reach the Macs over Tailscale from anywhere, which is the whole point of
/// this path.
///
/// `sendMessage(_:replyHandler:)` rather than a background transfer: it wakes
/// the counterpart iOS app if it is suspended and answers immediately, which
/// suits a display that only polls while someone is looking at it. Application
/// context would arrive eventually; eventually is not useful on a wrist.
@MainActor
final class PhoneLink: NSObject, ObservableObject {
  static let shared = PhoneLink()

  private var session: WCSession? {
    WCSession.isSupported() ? .default : nil
  }

  func activate() {
    guard let session else { return }
    session.delegate = self
    if session.activationState != .activated { session.activate() }
  }

  /// Fleet state from the phone, or nil if it cannot answer.
  ///
  /// Nil rather than zeroes: "the phone did not answer" and "the fleet is
  /// idle" are different, and showing an idle fleet for an unreachable one is
  /// the same class of lie the direct path already told once.
  func fleet() async -> (inFlight: Int, throughput: Double, nodes: Int)? {
    guard let session, session.activationState == .activated, session.isReachable
    else { return nil }
    return await withCheckedContinuation { continuation in
      var resumed = false
      session.sendMessage(["ask": "fleet"]) { reply in
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: (
          reply["inFlight"] as? Int ?? 0,
          reply["throughput"] as? Double ?? 0,
          reply["nodes"] as? Int ?? 0
        ))
      } errorHandler: { _ in
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: nil)
      }
    }
  }
}

extension PhoneLink: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
    error: Error?
  ) {}
}
