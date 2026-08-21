import SwiftUI

/// Ambient connected-state display: symbols falling in columns.
///
/// This is the app's resting state once the node joins the mesh — the device
/// is working but has nothing to ask of anyone, so it says so without
/// occupying a screen. Tapping anywhere reveals the console.
///
/// Drawn as a single `TimelineView`/`Canvas` pass rather than a stack of
/// animated views: one draw call per frame keeps this cheap enough to leave
/// running on a device that is also holding 2.3 GB of model weights. Every
/// visual property is derived arithmetically from column and row indices, so
/// the field never repeats and nothing per-cell is stored.
struct MatrixRain: View {
  /// Half-width katakana and geometric sigils. Deliberately no digits: a
  /// number reads as data the viewer tries to interpret, which pulls attention
  /// out of the ambient state and into decoding. Symbols stay texture.
  private static let glyphs = Array(
    "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝｦｯｬｭｮ╱╲◢◣◤◥▓▒░┼╬╫╪"
  )

  /// Scales every metric together. The thumbnail passes a smaller value so the
  /// miniature reads as the same field rather than a cropped corner of it.
  var scale: CGFloat = 1

  /// Fills a large display without simply showing more, smaller columns.
  ///
  /// A 13" iPad at scale 1 renders roughly three times the columns of a phone,
  /// which reads as noise rather than rain — the eye loses individual trails.
  /// Scaling the glyphs up with the display keeps the column count and the
  /// sense of falling intact, so the field reads the same at arm's length on a
  /// tablet as it does in the hand.
  static func fitting(_ size: CGSize) -> CGFloat {
    let shorter = min(size.width, size.height)
    switch shorter {
    case ..<500: return 1.0     // phone
    case ..<800: return 1.5     // small tablet
    default: return 1.9         // 13" and larger
    }
  }

  private var columnWidth: CGFloat { 20 * scale }
  private var rowHeight: CGFloat { 22 * scale }
  private var glyphSize: CGFloat { 18 * scale }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      Canvas(rendersAsynchronously: true) { context, size in
        let time = timeline.date.timeIntervalSinceReferenceDate
        // Bloom: the whole field glows into itself, so bright heads bleed
        // light onto their neighbours the way phosphor does.
        context.addFilter(.blur(radius: 0.6 * scale))
        draw(in: &context, size: size, time: time)
      }
      .background(.black)
      .overlay { scanlines }
    }
    .ignoresSafeArea()
  }

  /// Fine horizontal banding. Costs one gradient and sells the idea that this
  /// is a display rather than a drawing.
  private var scanlines: some View {
    GeometryReader { proxy in
      Canvas { context, size in
        let spacing = 3.0 * scale
        var y = 0.0
        while y < size.height {
          context.fill(
            Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
            with: .color(.black.opacity(0.22))
          )
          y += spacing
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .allowsHitTesting(false)
      .blendMode(.multiply)
    }
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
    let columns = max(1, Int(size.width / columnWidth) + 1)
    let rows = max(1, Int(size.height / rowHeight) + 3)

    for column in 0..<columns {
      // Speed, phase, and trail length all come from the column index, so no
      // two columns share a rhythm and the field never visibly loops.
      let speed = 3.5 + Double((column &* 37) % 13) * 0.9
      let phase = Double((column &* 53) % 101)
      let trail = 10 + (column &* 7) % 16
      let span = Double(rows) + Double(trail)
      let head = (time * speed + phase).truncatingRemainder(dividingBy: span)

      // Columns breathe: a slow sine on brightness keeps the whole field
      // moving even where glyphs happen to be static.
      let breath = 0.75 + 0.25 * sin(time * 0.6 + Double(column) * 0.4)

      for offset in 0..<trail {
        let row = Int(head) - offset
        guard row >= 0, row < rows else { continue }

        let fade = 1.0 - (Double(offset) / Double(trail))
        let isHead = offset == 0
        let isNearHead = offset < 3

        // Flicker rate falls off down the trail: heads churn, tails settle.
        // That difference is most of what makes the field feel alive.
        let churn = isNearHead ? 14.0 : 3.0
        let seed = abs(column &* 31 &+ row &* 17 &+ Int(time * churn)) % Self.glyphs.count
        let glyph = String(Self.glyphs[seed])

        // The head is smoke, not a spark: a pale green held well below full
        // opacity so it reads as luminous vapour rather than a hard pixel.
        // White heads made each column terminate in a full stop; translucent
        // ones let the field breathe as one surface.
        let opacity = isHead ? 0.62 * breath : pow(fade, 1.4) * 0.7 * breath
        let color: Color =
          isHead
          ? Color(red: 0.68, green: 1.0, blue: 0.80).opacity(opacity)
          : isNearHead
            ? Color(red: 0.45, green: 0.98, blue: 0.62).opacity(opacity)
            : Color(red: 0.16, green: 0.94, blue: 0.36).opacity(opacity)

        let point = CGPoint(
          x: CGFloat(column) * columnWidth + columnWidth / 2,
          y: CGFloat(row) * rowHeight
        )

        // Heads get a second, wider, dimmer pass beneath them. Two draws is
        // far cheaper than a real glow and reads almost the same in motion.
        if isHead {
          // Two soft passes instead of one hard one. The wider, dimmer draw
          // underneath is what turns a glyph into a diffuse bloom of smoke.
          let outer = context.resolve(
            Text(glyph)
              .font(.system(size: glyphSize * 1.6, weight: .light, design: .monospaced))
              .foregroundStyle(Color(red: 0.50, green: 1.0, blue: 0.68).opacity(0.14 * breath))
          )
          context.draw(outer, at: point)
          let inner = context.resolve(
            Text(glyph)
              .font(.system(size: glyphSize * 1.22, weight: .regular, design: .monospaced))
              .foregroundStyle(Color(red: 0.60, green: 1.0, blue: 0.74).opacity(0.22 * breath))
          )
          context.draw(inner, at: point)
        }

        let resolved = context.resolve(
          Text(glyph)
            .font(
              .system(
                size: glyphSize,
                weight: isHead ? .regular : isNearHead ? .medium : .regular,
                design: .monospaced
              )
            )
            .foregroundStyle(color)
        )
        context.draw(resolved, at: point)
      }
    }
  }
}
