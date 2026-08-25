import SwiftUI

/// The monitor's whole palette, in one place.
///
/// Three signal colours and nothing else. They are not decoration: a colour
/// here always answers "what should I do about this node", so anything that
/// does not need acting on stays neutral. A screen where everything is tinted
/// says nothing at a glance, which is the only thing a monitor is for.
enum Palette {
  /// Serving. The only green on screen.
  static let live = Color(red: 0.25, green: 0.88, blue: 0.54)
  /// Reachable but degrading — fair thermal, or a node throttling itself.
  static let warn = Color(red: 0.96, green: 0.64, blue: 0.24)
  /// Unreachable, or thermally past the point of useful work.
  static let fault = Color(red: 0.94, green: 0.34, blue: 0.29)

  static let ink = Color.white
  static let dim = Color.white.opacity(0.45)
  static let faint = Color.white.opacity(0.24)
  static let hairline = Color.white.opacity(0.07)

  /// Black, with just enough falloff that glass has something to sit on.
  /// Over a perfectly flat fill the material renders as a grey rectangle.
  static let ground = LinearGradient(
    colors: [Color(white: 0.0), Color(red: 0.035, green: 0.042, blue: 0.05)],
    startPoint: .top, endPoint: .bottom
  )
}

extension FleetNode {
  /// What this node's state means, as a colour.
  var signal: Color {
    guard state == .reachable else { return Palette.fault }
    switch (thermal ?? "").lowercased() {
    case "serious", "critical": return Palette.fault
    case "fair": return Palette.warn
    default: return (inFlight ?? 0) > 0 ? Palette.live : Palette.faint
    }
  }

  /// Neutral unless it needs attention — a working node is green, a quiet
  /// healthy one is simply not coloured.
  var isNoteworthy: Bool { signal == Palette.fault || signal == Palette.warn }
}
