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
          Text(String(format: "%.0f tok/s%@", watcher.tokensPerSecond,
                      watcher.viaPhone ? " ·phone" : ""))
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .foregroundStyle(Color(red: 0.45, green: 0.98, blue: 0.6))
            .transition(.opacity)
        } else {
          // Always show the count, not just the zero case. "no fleet" alone
          // cannot distinguish a quiet fleet from an unreachable one, which is
          // exactly the ambiguity that hid a total polling failure.
          Text(watcher.reachableNodes == 0
            ? "no fleet"
            : "\(watcher.reachableNodes) idle\(watcher.viaPhone ? " ·phone" : "")")
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
