import SwiftUI

/// Wraps to 0..<1. File-scoped so every helper shares one definition.
private func fract(_ value: Double) -> Double {
  value - value.rounded(.down)
}

/// Fine drifting particles on black — the setup-screen idiom, borrowed as a
/// fleet indicator.
///
/// Idle: whites, grays, and blues wandering slowly. Working: the same field
/// eased into greens. The particles never jump between states; their colour
/// crossfades over a second and a half, so engagement reads as the field
/// changing weather rather than a screen being swapped.
///
/// Every particle's position is a pure function of time and its seed — nothing
/// is stored or stepped per frame. That keeps the draw loop allocation-free,
/// which matters on a watch, and makes the field deterministic: the same
/// second always looks the same.
struct ParticleField: View {
  let engaged: Bool
  let transitionedAt: Date

  private static let count = 140

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
      Canvas { context, size in
        let now = timeline.date
        let time = now.timeIntervalSinceReferenceDate
        // 0 fully idle, 1 fully working, eased across 1.5 s from the flip.
        let progress = min(1, max(0, now.timeIntervalSince(transitionedAt) / 1.5))
        let activation = engaged ? progress : 1 - progress

        for index in 0..<Self.count {
          let seed = Double(index)
          // Layered drift: a slow base direction per particle plus two sine
          // wanders at different periods. Wrapped, so the field never empties.
          let speedX = 4.0 + 7.0 * fract(seed * 0.731)
          let speedY = 3.0 + 6.0 * fract(seed * 0.377)
          let directionX: Double = fract(seed * 0.191) > 0.5 ? 1 : -1
          let directionY: Double = fract(seed * 0.613) > 0.5 ? 1 : -1
          var x = fract(seed * 0.618 + directionX * speedX * time / 900)
          var y = fract(seed * 0.414 + directionY * speedY * time / 900)
          x += 0.015 * sin(time / 7 + seed * 1.7)
          y += 0.015 * cos(time / 9 + seed * 2.3)
          let point = CGPoint(
            x: fract(x) * size.width,
            y: fract(y) * size.height
          )

          // Tiny: sub-point to a couple of points, with a slow shimmer.
          let radius = 0.5 + 0.75 * fract(seed * 0.529)
          let shimmer = 0.55 + 0.45 * sin(time / 3 + seed * 4.1)

          let color = Self.color(seed: seed, activation: activation)
          context.fill(
            Path(
              ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2)),
            with: .color(color.opacity(0.35 + 0.5 * shimmer))
          )
        }
      }
      .background(.black)
    }
  }

  /// Idle palette: white / gray / soft blue by seed. Working palette: three
  /// greens. Blended by activation so the shift is a crossfade, not a cut.
  private static func color(seed: Double, activation: Double) -> Color {
    let bucket = fract(seed * 0.917)
    let idle: (Double, Double, Double) =
      bucket < 0.45
      ? (0.92, 0.94, 0.97)  // white
      : bucket < 0.75
        ? (0.55, 0.58, 0.64)  // gray
        : (0.40, 0.60, 0.95)  // blue
    let working: (Double, Double, Double) =
      bucket < 0.45
      ? (0.72, 1.0, 0.80)  // pale green
      : bucket < 0.75
        ? (0.25, 0.85, 0.45)  // mid green
        : (0.10, 0.60, 0.30)  // deep green
    return Color(
      red: idle.0 + (working.0 - idle.0) * activation,
      green: idle.1 + (working.1 - idle.1) * activation,
      blue: idle.2 + (working.2 - idle.2) * activation
    )
  }
}
