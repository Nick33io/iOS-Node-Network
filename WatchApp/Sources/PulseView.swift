import SwiftUI

struct PulseView: View {
  @State private var watcher = FleetWatcher()

  var body: some View {
    ZStack {
      ParticleField(
        engaged: watcher.engaged,
        transitionedAt: watcher.transitionedAt
      )
      VStack {
        Spacer()
        if watcher.engaged {
          Text(String(format: "%.0f tok/s", watcher.tokensPerSecond))
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .foregroundStyle(Color(red: 0.45, green: 0.98, blue: 0.6))
            .transition(.opacity)
        } else if watcher.reachableNodes == 0 {
          Text("no fleet")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.bottom, 8)
      .animation(.easeInOut(duration: 0.4), value: watcher.engaged)
    }
    .ignoresSafeArea()
    .onAppear { watcher.start() }
    .onDisappear { watcher.stop() }
    // Demo hook, so the working state can be seen without a live fleet.
    .task {
      if ProcessInfo.processInfo.arguments.contains("-demo") {
        watcher.stop()
      }
    }
  }
}
