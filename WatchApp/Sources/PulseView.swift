import SwiftUI

struct PulseView: View {
  @State private var watcher = FleetWatcher()
  @State private var touchPoint: CGPoint?
  @State private var lastTouchPoint: CGPoint = .zero
  @State private var touchEndedAt = Date.distantPast
  /// Raw crown position. Continuous, so it never hits a stop.
  @State private var crown: Double = 0
  /// Rolling measure of how hard the dial is being turned, 0...1.
  @State private var crownEnergy: Double = 0
  @State private var crownEndedAt = Date.distantPast
  /// The crown only reports to a view that actually holds focus, and
  /// `.focusable()` alone does not grant it — this claims it on appear.
  @FocusState private var crownFocused: Bool

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
    .onAppear {
      watcher.start()
      // Claim the crown for the field: without focus the rotation binding
      // never fires and the dial appears to do nothing at all.
      crownFocused = true
    }
    .onDisappear { watcher.stop() }
  }

  private var field: some View {
    var view = ParticleField(
      engaged: watcher.engaged,
      transitionedAt: watcher.transitionedAt,
      touch: touchPoint,
      touchEndedAt: touchEndedAt,
      crownEnergy: crownEnergy,
      crownEndedAt: crownEndedAt
    )
    view.lastTouchPoint = lastTouchPoint
    return
      view
      /*
       * The crown excites the dust (owner-directed 2026-08-26). Energy
       * accumulates with how fast the dial moves and bleeds away between
       * ticks, so a slow turn glows and a fast spin goes fully neon. The
       * field owns the ease-out: this only records how hard, and when last
       * — it never has to be told to stop.
       */
      .focusable(true)
      .focused($crownFocused)
      .digitalCrownRotation(
        $crown,
        from: -100_000,
        through: 100_000,
        by: 1,
        sensitivity: .medium,
        isContinuous: true,
        isHapticFeedbackEnabled: true
      )
      .onChange(of: crown) { previous, current in
        // Rate, not distance: a detent is the same size however fast it
        // arrives, so only the time between them says how hard the dial is
        // being turned. The first change after a rest has no usable interval
        // and is charged at a nominal one.
        let now = Date()
        let sinceLast = now.timeIntervalSince(crownEndedAt)
        let interval = sinceLast > 0 && sinceLast < 0.5 ? sinceLast : 0.06
        let speed = abs(current - previous) / interval
        // A brisk turn runs a few detents a second; normalise there so an
        // ordinary flick reaches full neon rather than a hint of it.
        crownEnergy = min(1, crownEnergy * 0.7 + min(1, speed / 12) * 0.7)
        crownEndedAt = now
      }
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
