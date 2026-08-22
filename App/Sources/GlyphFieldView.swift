import SwiftUI

/// Draws a `GlyphFrame` as a stable image made of glyphs.
///
/// The picture must not move. An earlier version drifted each column downward
/// to suggest a live signal, which scrambled the frame into falling columns —
/// the subject dissolved and all that was left was rain. Position carries the
/// image; motion comes from the glyphs *changing in place*, which is what the
/// reference footage actually does.
struct GlyphFieldView: View {
  let frame: GlyphFrame

  /// How fast glyphs churn, in shuffles per second. Fast enough to shimmer,
  /// slow enough that a face stays a face between frames.
  private static let churn = 9.0

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
      Canvas(rendersAsynchronously: true) { context, size in
        guard frame.columns > 0, frame.rows > 0 else { return }
        context.addFilter(.blur(radius: 0.45))
        draw(in: &context, size: size, tick: Int(timeline.date.timeIntervalSinceReferenceDate * Self.churn))
      }
      .background(.black)
    }
    .ignoresSafeArea()
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, tick: Int) {
    let cellWidth = size.width / CGFloat(frame.columns)
    let cellHeight = size.height / CGFloat(frame.rows)
    let glyphSize = min(cellWidth, cellHeight) * 1.25

    for row in 0..<frame.rows {
      for column in 0..<frame.columns {
        let index = row * frame.columns + column
        let level = frame.levels[index]
        // Shadow. Drawing it would grey the blacks and cost a text resolve for
        // something invisible — and the reference is mostly black.
        guard level > 20 else { continue }

        let isSubject = frame.subject[index]
        let normalized = Double(level) / 255.0

        // Structure stays a faint deep green; people take the brighter, warmer
        // range. That split is what makes a figure legible against a wall lit
        // to the same luminance, and it is the thing the reference does that
        // plain ASCII art does not.
        let color: Color =
          isSubject
          ? Color(
            red: 0.35 + 0.50 * normalized,
            green: 0.88 + 0.12 * normalized,
            blue: 0.42 + 0.28 * normalized
          ).opacity(0.55 + 0.45 * normalized)
          : Color(red: 0.04, green: 0.42 + 0.34 * normalized, blue: 0.13)
            .opacity(0.22 + 0.38 * normalized)

        // The glyph varies over time, the density does not. Jittering by one
        // step keeps the cell's apparent tone — which is what carries the
        // image — while the character underneath keeps changing.
        let base = Int(frame.glyphs[index])
        let jitter = ((column &* 31) ^ (row &* 17) ^ (tick &* 7)) % 3 - 1
        let chosen = UInt8(max(0, min(GlyphRamp.characters.count - 1, base + jitter)))

        let resolved = context.resolve(
          Text(String(GlyphRamp.character(at: chosen)))
            .font(
              .system(
                size: glyphSize,
                weight: isSubject ? .semibold : .regular,
                design: .monospaced
              )
            )
            .foregroundStyle(color)
        )
        // Fixed position. This is the image.
        context.draw(
          resolved,
          at: CGPoint(
            x: CGFloat(column) * cellWidth + cellWidth / 2,
            y: CGFloat(row) * cellHeight + cellHeight / 2
          )
        )
      }
    }
  }
}
