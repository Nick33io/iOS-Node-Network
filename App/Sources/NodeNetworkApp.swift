import SwiftUI

@main
struct NodeNetworkApp: App {
  var body: some Scene {
    WindowGroup {
      // One app, two jobs: the iPad manages the fleet, everything else is a
      // worker node. See NodeRole.
      switch NodeRole.current {
      case .manager:
        ManagerView()
      case .node:
        RootView()
          .preferredColorScheme(.dark)
      }
    }
  }
}
