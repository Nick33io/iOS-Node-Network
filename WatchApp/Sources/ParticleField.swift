import SwiftUI

/// Wraps to 0..<1.
private func fract(_ value: Double) -> Double {
  value - value.rounded(.down)
}

/// The pairing-screen nebula, borrowed as a fleet indicator.
///
/// Matched to the reference: not particles scattered across the screen but a
/// dense spherical cloud centred on the face — a core that reads as dust, a
/// ragged irregular rim, slow rotation with depth, and a fine sparkle. Idle it
/// sits in whites, ice blues, and violets; when the fleet engages the same
/// cloud crossfades to greens over a second and a half.
///
/// ~1,400 particles at 20 fps on a watch works only because nothing is stored:
/// every particle's 3D position is a pure function of time and its seed,
/// projected each frame. Drawing is batched — particles append to one path per
/// colour-and-brightness bucket, so the frame costs a dozen fills rather than
/// fourteen hundred.
///
/// Touch pushes the dust aside: a gaussian displacement around the finger,
/// easing out over a second after release. The push is applied to projected
/// positions, so it costs one exp per particle only while a touch is active.
struct ParticleField: View {
  let engaged: Bool
  let transitionedAt: Date
  /// Finger location while touching, nil otherwise.
  let touch: CGPoint?
  /// When the last touch lifted, for the ease-out.
  let touchEndedAt: Date

  private static let count = 1400
  /// Alpha is quantised to these bands so batching survives the shimmer.
  private static let alphaBands: [Double] = [0.16, 0.38, 0.62, 0.92]

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
      Canvas { context, size in
        draw(in: &context, size: size, now: timeline.date)
      }
      .background(.black)
    }
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
    let time = now.timeIntervalSinceReferenceDate
    let progress = min(1, max(0, now.timeIntervalSince(transitionedAt) / 1.5))
    let activation = engaged ? progress : 1 - progress

    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let cloudRadius = min(size.width, size.height) * 0.42

    // Slow tumble: a steady spin with a lazy precession, like the reference.
    let spin = time * 0.14
    let tilt = 0.45 + 0.18 * sin(time * 0.05)

    // Touch influence decays over 1.1 s after the finger lifts.
    let touchDecay: Double
    if touch != nil {
      touchDecay = 1
    } else {
      let since = now.timeIntervalSince(touchEndedAt)
      touchDecay = since < 1.1 ? pow(1 - since / 1.1, 2) : 0
    }
    let activeTouch = touchDecay > 0.01 ? touch ?? lastTouchApproximation : nil

    // One path per colour bucket per alpha band; particles append, then each
    // batch fills once.
    var batches: [Path] = Array(repeating: Path(), count: 3 * Self.alphaBands.count)

    for index in 0..<Self.count {
      let seed = Double(index)

      // A point in the ball, dense at the core: direction uniform on the
      // sphere, radius pulled hard toward the centre.
      let u = fract(seed * 0.7548776662)
      let v = fract(seed * 0.5698402910)
      let w = fract(seed * 0.3183098862)
      let theta = 2 * .pi * u
      let cosPhi = 2 * v - 1
      let sinPhi = (1 - cosPhi * cosPhi).squareRoot()
      // pow > 1 packs radii inward — the "more in the centre" the reference
      // shows, with a sparse halo surviving at the rim.
      var radius = pow(w, 1.5)
      // Ragged rim: low-frequency lobes so the edge is a torn cloud, not a
      // circle.
      radius *= 1 + 0.16 * sin(3 * theta + seed * 0.7) * Double(min(1, radius * 2))

      var px = radius * sinPhi * cos(theta)
      var py = radius * cosPhi
      var pz = radius * sinPhi * sin(theta)

      // Per-particle breathing so the dust never sits still.
      px += 0.03 * sin(time * 0.7 + seed * 2.1)
      py += 0.03 * sin(time * 0.9 + seed * 1.3)
      pz += 0.03 * cos(time * 0.8 + seed * 1.7)

      // Tumble: rotate about Y (spin), then X (tilt).
      let x1 = px * cos(spin) + pz * sin(spin)
      let z1 = -px * sin(spin) + pz * cos(spin)
      let y2 = py * cos(tilt) - z1 * sin(tilt)
      let z2 = py * sin(tilt) + z1 * cos(tilt)

      var point = CGPoint(
        x: center.x + x1 * cloudRadius,
        y: center.y + y2 * cloudRadius
      )

      // Depth: nearer dust is larger and brighter.
      let depth = (z2 + 1) / 2  // 0 far, 1 near
      var dotRadius = 0.4 + 0.9 * depth * (0.6 + 0.4 * fract(seed * 0.437))

      if let finger = activeTouch {
        let dx = point.x - finger.x
        let dy = point.y - finger.y
        let distanceSquared = dx * dx + dy * dy
        let sigma: Double = 44
        let push = 30 * exp(-distanceSquared / (2 * sigma * sigma)) * touchDecay
        if push > 0.3 {
          let distance = max(1, distanceSquared.squareRoot())
          point.x += dx / distance * push
          point.y += dy / distance * push
          dotRadius *= 1 + push / 45  // displaced dust catches the light
        }
      }

      // Sparkle, folded into the quantised alpha so batching holds.
      let sparkle = 0.5 + 0.5 * sin(time * 2.6 + seed * 7.3)
      let brightness = (0.25 + 0.75 * depth) * (0.45 + 0.55 * sparkle)
      let band = min(
        Self.alphaBands.count - 1,
        Int(brightness * Double(Self.alphaBands.count)))
      let bucket = Int(fract(seed * 0.917) * 3)

      batches[bucket * Self.alphaBands.count + band].addEllipse(
        in: CGRect(
          x: point.x - dotRadius, y: point.y - dotRadius,
          width: dotRadius * 2, height: dotRadius * 2))
    }

    for bucket in 0..<3 {
      let color = Self.color(bucket: bucket, activation: activation)
      for band in 0..<Self.alphaBands.count {
        context.fill(
          batches[bucket * Self.alphaBands.count + band],
          with: .color(color.opacity(Self.alphaBands[band]))
        )
      }
    }
  }

  /// Where the ease-out centres when the finger has already lifted.
  private var lastTouchApproximation: CGPoint { touchResting }
  private var touchResting: CGPoint { lastTouchPoint }
  /// Stored by the parent alongside `touchEndedAt`.
  var lastTouchPoint: CGPoint = .zero

  /// Idle: white / ice blue / violet, the pairing-screen wash. Working: three
  /// greens. Blended by activation so the shift is weather, not a cut.
  private static func color(bucket: Int, activation: Double) -> Color {
    let idle: (Double, Double, Double) =
      bucket == 0
      ? (0.90, 0.93, 1.00)  // white
      : bucket == 1
        ? (0.52, 0.68, 1.00)  // ice blue
        : (0.60, 0.52, 0.95)  // violet
    let working: (Double, Double, Double) =
      bucket == 0
      ? (0.74, 1.00, 0.82)  // pale green
      : bucket == 1
        ? (0.28, 0.86, 0.48)  // mid green
        : (0.10, 0.58, 0.32)  // deep green
    return Color(
      red: idle.0 + (working.0 - idle.0) * activation,
      green: idle.1 + (working.1 - idle.1) * activation,
      blue: idle.2 + (working.2 - idle.2) * activation
    )
  }
}
