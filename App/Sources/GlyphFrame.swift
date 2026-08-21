import Foundation

/// One frame of the camera rendered as glyphs.
///
/// The capturing device does the camera work and the vision pass, then
/// broadcasts *this* — never pixels. A 60x40 grid is a couple of kilobytes, so
/// the whole fleet can watch at 15fps over the tailnet for less bandwidth than
/// a single JPEG, and no image ever leaves the device that captured it. That
/// second property is the one that matters: an ambient display should not turn
/// every screen in the room into a remote camera viewer.
struct GlyphFrame: Codable, Sendable, Equatable {
  /// Column count. Rows are derived from `cells.count / columns`.
  let columns: Int
  /// Row-major. Each byte is an index into `GlyphRamp.characters`.
  let glyphs: [UInt8]
  /// Row-major, 0...255. Drives brightness within the tone.
  let levels: [UInt8]
  /// Row-major mask: true where the vision pass found a person. People get a
  /// different tone so a figure reads as a figure and not as bright wall.
  let subject: [Bool]
  /// Monotonic frame counter, so a viewer can drop a frame that arrives late
  /// rather than showing motion running backwards.
  let sequence: Int

  var rows: Int { columns > 0 ? glyphs.count / columns : 0 }

  static let empty = GlyphFrame(columns: 0, glyphs: [], levels: [], subject: [], sequence: 0)
}

/// Luminance-to-glyph ramp, sparse to dense.
///
/// Ordered by how much ink each character puts on screen, which is what turns a
/// brightness value into apparent tone. The exact set matters less than the
/// monotonic density — a ramp that jumps around reads as noise rather than
/// shading.
enum GlyphRamp {
  static let characters: [Character] = Array(" .`',:;!~+-<>i?ﾉILJ7)(|ﾂﾞﾘﾂ]}1tfｱｲｳﾅﾆ[ﾊﾋxnuvczXYUJCLQ0OZmwqpdbkhaoｦｯｬ#MW&8%B@$")

  static func index(for level: UInt8) -> UInt8 {
    let scaled = Int(level) * (characters.count - 1) / 255
    return UInt8(max(0, min(characters.count - 1, scaled)))
  }

  static func character(at index: UInt8) -> Character {
    characters[Int(index) % characters.count]
  }
}
