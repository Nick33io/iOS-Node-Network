import SwiftUI

/// The fleet, watched from a Mac.
///
/// A viewer, never a worker: the Macs already serve through `NodeAgent` under
/// launchd, and a second process competing for the same GPU would cost
/// throughput to display throughput. This only reads.
@main
struct MonitorApp: App {
  var body: some Scene {
    WindowGroup {
      MonitorView()
        .frame(minWidth: 880, minHeight: 560)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1080, height: 700)
  }
}
