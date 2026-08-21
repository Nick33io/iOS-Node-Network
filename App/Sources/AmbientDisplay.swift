import Foundation
import Observation
import NodeKit

/// Decides which device runs the camera, and carries its frames to the rest.
///
/// Only one device should capture: several cameras in a room is confusing, and
/// the work is wasted. The holder is elected by installed memory from the same
/// `/health` data the fleet already reports — the largest device is the one
/// best able to spare a camera and a vision pass alongside whatever else it is
/// doing.
///
/// This is an ambient *display*, not a lock screen. iOS suspends a backgrounded
/// app, so a locked phone or iPad cannot capture or render — the device has to
/// be awake with NOD3 in front. Presenting it as a lock screen would be
/// promising something the platform does not allow.
@MainActor
@Observable
final class AmbientDisplay {
  enum Role: Equatable {
    /// This device runs the camera and serves frames.
    case source
    /// This device shows frames from `host`.
    case viewer(host: String)
    /// Nothing is capturing.
    case idle
  }

  var role: Role = .idle
  var frame: GlyphFrame = .empty
  var lastError: String?

  private var pollTask: Task<Void, Never>?

  /// Elects a source from what the fleet reports.
  ///
  /// Ties break on host so every device independently reaches the same answer
  /// without needing to agree with anyone — election by sort, not by protocol.
  static func electSource(
    from nodes: [(host: String, memoryGiB: Double, reachable: Bool, camera: Bool)],
    localHost: String
  ) -> Role {
    let candidates =
      nodes
      .filter { $0.reachable && $0.camera }
      .sorted { ($0.memoryGiB, $1.host) > ($1.memoryGiB, $0.host) }
    guard let winner = candidates.first else { return .idle }
    return winner.host == localHost ? .source : .viewer(host: winner.host)
  }

  /// Pulls frames from the elected source.
  ///
  /// Polling rather than a push socket: a viewer that sleeps simply stops
  /// asking, which is the same failure mode the rest of the mesh already has,
  /// and it needs no server-side connection tracking.
  func follow(host: String) {
    pollTask?.cancel()
    role = .viewer(host: host)
    pollTask = Task { [weak self] in
      var lastSequence = -1
      while !Task.isCancelled {
        do {
          var request = URLRequest(url: URL(string: "http://\(host):8833/glyphs")!)
          request.timeoutInterval = 3
          let (data, _) = try await URLSession.shared.data(for: request)
          let decoded = try JSONDecoder().decode(GlyphFrame.self, from: data)
          // A frame that arrives out of order would run motion backwards.
          if decoded.sequence > lastSequence {
            lastSequence = decoded.sequence
            await MainActor.run { self?.frame = decoded }
          }
        } catch {
          await MainActor.run { self?.lastError = String(describing: error).prefix(60).description }
          try? await Task.sleep(for: .seconds(2))
        }
        try? await Task.sleep(for: .milliseconds(66))
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
    role = .idle
    frame = .empty
  }
}
