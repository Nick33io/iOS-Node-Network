import SwiftUI

/// A horizontal bar reading.
///
/// Bars rather than dials throughout: they stack, they share a left edge, and a
/// column of them can be compared at a glance without reading any numbers —
/// which is the point of an instrument panel as opposed to a list of values.
struct Meter: View {
  let key: String
  let value: String
  /// 0...1.
  let fraction: Double
  var tint: Color = .green
  /// Above this the bar turns amber, then red. Nil for readings where high is
  /// not bad — bandwidth and throughput are wanted, not warned about.
  var warnAbove: Double?

  private var barColor: Color {
    guard let warnAbove else { return tint }
    if fraction >= 0.9 { return .red }
    if fraction >= warnAbove { return .orange }
    return tint
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(key)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
        Spacer()
        Text(value)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(barColor)
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1)
            .fill(.white.opacity(0.07))
          RoundedRectangle(cornerRadius: 1)
            .fill(barColor.opacity(0.85))
            .frame(width: max(0, proxy.size.width * min(1, max(0, fraction))))
        }
      }
      .frame(height: 3)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(key): \(value)")
  }
}

/// Connected or not. Deliberately just a dot — a node is either reachable or it
/// is not, and any further nuance belongs in the readings below it.
struct StatusDot: View {
  let isUp: Bool
  var body: some View {
    Circle()
      .fill(isUp ? Color.green : Color.red)
      .frame(width: 9, height: 9)
      .shadow(color: (isUp ? Color.green : Color.red).opacity(0.7), radius: 4)
      .accessibilityLabel(isUp ? "Connected" : "Not connected")
  }
}
