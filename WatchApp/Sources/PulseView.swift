import SwiftUI

struct PulseView: View {
  @State private var watcher = FleetWatcher()
  @State private var touchPoint: CGPoint?
  @State private var lastTouchPoint: CGPoint = .zero
  @State private var touchEndedAt = Date.distantPast

  var body: some View {
    ZStack {
      field
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
      .padding(.bottom, 6)
      .animation(.easeInOut(duration: 0.4), value: watcher.engaged)
    }
    .ignoresSafeArea()
    .onAppear { watcher.start() }
    .onDisappear { watcher.stop() }
  }

  private var field: some View {
    var view = ParticleField(
      engaged: watcher.engaged,
      transitionedAt: watcher.transitionedAt,
      touch: touchPoint,
      touchEndedAt: touchEndedAt
    )
    view.lastTouchPoint = lastTouchPoint
    return
      view
      // minimumDistance 0 so a resting finger disturbs the dust immediately —
      // the reference responds to contact, not to movement.
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            touchPoint = value.location
            lastTouchPoint = value.location
          }
          .onEnded { _ in
            touchPoint = nil
            touchEndedAt = Date()
          }
      )
  }
}
