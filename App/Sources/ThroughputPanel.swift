import SwiftUI
import NodeKit

/// Every node's throughput in one place.
///
/// The per-node cards carry throughput too, but scattered across a grid they
/// cannot be compared — the eye has to hold six numbers at once. Stacking the
/// bars against a shared ceiling turns that into a single glance, which is the
/// only way a fleet reading is actually useful.
struct ThroughputPanel: View {
  let nodes: [FleetNode]
  /// This device, which never appears in its own probe results as a rate.
  let selfLabel: String
  let selfRate: Double
  let isRunning: Bool

  /// Shared scale for every bar. Fixed rather than normalised to the current
  /// maximum, so a bar means the same thing between refreshes and a fast node
  /// does not shrink everyone else.
  private static let ceiling: Double = 100

  private struct Reading: Identifiable {
    let id: String
    let label: String
    let rate: Double
    let tier: NodeTier?
    let reachable: Boolean
    typealias Boolean = Bool
  }

  private var readings: [Reading] {
    var rows = nodes.filter { $0.aliasOf == nil }.map {
      Reading(
        id: $0.id, label: $0.label, rate: $0.tokensPerSecond ?? 0,
        tier: $0.tier, reachable: $0.isReachable)
    }
    if !rows.contains(where: { $0.label == selfLabel }) {
      rows.insert(
        Reading(id: "self", label: selfLabel, rate: selfRate, tier: NodeTier.current(), reachable: true),
        at: 0)
    }
    return rows.sorted { $0.rate > $1.rate }
  }

  private var aggregate: Double { readings.reduce(0) { $0 + $1.rate } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("THROUGHPUT")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .tracking(2)
        Spacer()
        if isRunning {
          Text("running")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.green)
        }
        Text(String(format: "%.0f tok/s fleet", aggregate))
          .font(.system(.caption, design: .monospaced).weight(.semibold))
          .foregroundStyle(aggregate > 0 ? Color.green : Color.secondary)
      }

      ForEach(readings) { row in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Circle()
              .fill(row.reachable ? (row.tier == .permanent ? Color.green : Color.yellow) : Color.red)
              .frame(width: 6, height: 6)
            Text(row.label)
              .font(.system(.caption2, design: .monospaced))
              .lineLimit(1)
            Spacer()
            Text(row.rate > 0 ? String(format: "%.1f", row.rate) : "—")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(row.rate > 0 ? Color.green : Color.secondary)
          }
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.06))
              RoundedRectangle(cornerRadius: 1)
                // Permanent nodes green, burst yellow — the same colour the
                // tier carries everywhere else, so capacity and reliability
                // read together.
                .fill((row.tier == .permanent ? Color.green : Color.yellow).opacity(0.8))
                .frame(width: proxy.size.width * min(1, row.rate / Self.ceiling))
            }
          }
          .frame(height: 3)
        }
      }
    }
  }
}
