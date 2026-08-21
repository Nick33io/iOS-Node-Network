import SwiftUI

/// Draws a `GlyphFrame`.
///
/// One `Canvas` pass, same as the synthetic rain, because this may be running
/// on a device that is also holding model weights and generating text. Text is
/// resolved per cell, which is the expensive part — but the grid is ~2800 cells
/// and the alternative (an attributed string per row) reflows on every frame.
struct GlyphFieldView: View {
  let frame: GlyphFrame
  /// Faint downward drift so a still room still reads as a live signal rather
  /// than a frozen image.
  var drift: Bool = true

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
      Canvas(rendersAsynchronously: true) { context, size in
        guard frame.columns > 0, frame.rows > 0 else { return }
        context.addFilter(.blur(radius: 0.5))
        draw(
          in: &context, size: size,
          time: timeline.date.timeIntervalSinceReferenceDate
        )
      }
      .background(.black)
    }
    .ignoresSafeArea()
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
    let cellWidth = size.width / CGFloat(frame.columns)
    let cellHeight = size.height / CGFloat(frame.rows)
    let glyphSize = min(cellWidth, cellHeight) * 1.15

    for row in 0..<frame.rows {
      for column in 0..<frame.columns {
        let index = row * frame.columns + column
        let level = frame.levels[index]
        // Below this the cell is shadow. Drawing it would grey the blacks and
        // cost a text resolve for something invisible.
        guard level > 18 else { continue }

        let isSubject = frame.subject[index]
        let normalized = Double(level) / 255.0

        // Structure stays a faint deep green; people get the brighter, warmer
        // range. The split is what makes a figure legible against a wall lit to
        // the same luminance.
        let color: Color =
          isSubject
          ? Color(
            red: 0.30 + 0.55 * normalized,
            green: 0.85 + 0.15 * normalized,
            blue: 0.36 + 0.30 * normalized
          ).opacity(0.45 + 0.55 * normalized)
          : Color(red: 0.05, green: 0.55 + 0.30 * normalized, blue: 0.16)
            .opacity(0.18 + 0.42 * normalized)

        // Scroll each column at its own rate. The glyph is chosen by
        // brightness; the drift only moves which row it lands on, so the image
        // holds while the field keeps moving.
        var y = CGFloat(row) * cellHeight
        if drift {
          let speed = 6.0 + Double((column &* 29) % 7)
          let offset = (time * speed).truncatingRemainder(dividingBy: Double(cellHeight))
          y += CGFloat(offset)
          if y > size.height { y -= size.height }
        }

        let resolved = context.resolve(
          Text(String(GlyphRamp.character(at: frame.glyphs[index])))
            .font(.system(size: glyphSize, weight: isSubject ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(color)
        )
        context.draw(
          resolved,
          at: CGPoint(x: CGFloat(column) * cellWidth + cellWidth / 2, y: y)
        )
      }
    }
  }
}
