import SwiftUI

/// NOD3 Pulse — the fleet on the wrist.
///
/// A display, deliberately not a node. watchOS has no MLX runtime, an app
/// memory ceiling far below the smallest model, and no Tailscale client — so
/// the watch's honest job is to show whether the fleet is working, and how
/// hard, without asking anyone to look at a screen.
@main
struct PulseApp: App {
  var body: some Scene {
    WindowGroup {
      PulseView()
    }
  }
}
