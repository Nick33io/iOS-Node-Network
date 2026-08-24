import SwiftUI
import UIKit

/// Keeps a serving node awake at the lowest survivable cost.
///
/// iOS gives no supported way to serve with the screen off: a backgrounded app
/// is suspended within seconds and the listener dies with it. There are known
/// tricks — playing silent audio, or holding a location session — that keep a
/// process alive behind a dark screen, but both drain more power than the
/// screen they avoid and neither is a contract Apple honours.
///
/// So the screen stays on, and the cost is attacked directly instead: hold the
/// idle timer and drop brightness to near-black after a period of no
/// interaction. A dimmed panel is a small fraction of a lit one, which makes
/// the difference between a node that survives the night and one that does
/// not.
@MainActor
@Observable
final class ScreenKeeper {
  private(set) var isDimmed = false
  private(set) var isHolding = false

  /// Brightness before dimming, so the device is left as it was found.
  private var restoreLevel: CGFloat = UIScreen.main.brightness
  private var dimTask: Task<Void, Never>?

  /// Seconds of no interaction before dimming.
  var idleBeforeDim: TimeInterval = 60
  /// Not zero: a fully black panel reads as a crashed device, and someone
  /// walking past should be able to see the node is alive.
  var dimmedLevel: CGFloat = 0.02

  /// Begins holding the screen awake and dimming when idle.
  func hold() {
    guard !isHolding else { return }
    isHolding = true
    restoreLevel = UIScreen.main.brightness
    UIApplication.shared.isIdleTimerDisabled = true
    scheduleDim()
  }

  func release() {
    dimTask?.cancel()
    dimTask = nil
    isHolding = false
    UIApplication.shared.isIdleTimerDisabled = false
    undim()
  }

  /// Call on any interaction. Restores brightness and restarts the idle timer.
  func touched() {
    guard isHolding else { return }
    undim()
    scheduleDim()
  }

  private func scheduleDim() {
    dimTask?.cancel()
    dimTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: .seconds(self.idleBeforeDim))
      guard !Task.isCancelled, self.isHolding else { return }
      self.dim()
    }
  }

  private func dim() {
    guard !isDimmed else { return }
    restoreLevel = UIScreen.main.brightness
    // Animated so it reads as the device settling rather than failing.
    UIView.animate(withDuration: 1.2) {
      UIScreen.main.brightness = self.dimmedLevel
    }
    isDimmed = true
  }

  private func undim() {
    guard isDimmed else { return }
    UIScreen.main.brightness = restoreLevel
    isDimmed = false
  }
}
