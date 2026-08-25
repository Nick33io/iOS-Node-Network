import SwiftUI

/// What the fleet is doing, in the terms the iPad console uses.
///
/// Counts before rates. A number of machines answers "is the fleet there",
/// which has to be true before a throughput figure means anything at all.
struct SummaryModule: View {
  let permanentUp: Int
  let permanentTotal: Int
  let burstUp: Int
  let burstTotal: Int
  let throughput: Double
  let lastSweep: Date?
  let autoRefresh: Bool
  let interval: TimeInterval
  let refreshing: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 26) {
      stat("permanent", "\(permanentUp)/\(permanentTotal)",
           tint: permanentUp > 0 ? Palette.live : Palette.fault)
      stat("burst", "\(burstUp)/\(burstTotal)",
           tint: burstUp > 0 ? Palette.warn : Palette.faint)
      stat("fleet throughput",
           throughput > 0 ? String(format: "%.0f tok/s", throughput) : "idle",
           tint: throughput > 0 ? Palette.live : Palette.faint)
      if let swept = lastSweep {
        stat("last sweep", swept.formatted(date: .omitted, time: .standard))
      }
      stat("auto", autoRefresh ? "\(Int(interval))s" : "off",
           tint: autoRefresh ? Palette.live : Palette.faint)
      Spacer(minLength: 0)
      if refreshing {
        ProgressView()
          .controlSize(.small)
          .tint(Palette.live)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
  }

  private func stat(_ key: String, _ value: String, tint: Color = Palette.ink.opacity(0.85))
    -> some View
  {
    VStack(alignment: .leading, spacing: 5) {
      Text(key.uppercased())
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .tracking(1.4)
        .foregroundStyle(Palette.faint)
      Text(value)
        .font(.system(size: 17, weight: .light, design: .monospaced))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
        .lineLimit(1)
    }
  }
}
