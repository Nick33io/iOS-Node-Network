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
    // Every roster entry appears, including nodes that are down — a fleet view
    // that hides absent nodes makes a shrinking fleet look like a healthy one.
    var rows = nodes.filter { $0.aliasOf == nil }.map { node in
      Reading(
        id: node.id,
        label: node.label,
        // A self entry carries this device's own served rate, which its own
        // probe cannot report: it answers locally and never asks itself.
        rate: node.isSelf ? max(selfRate, node.tokensPerSecond ?? 0) : (node.tokensPerSecond ?? 0),
        tier: node.tier,
        reachable: node.isReachable)
    }
    // Only add a synthetic self row when this device is genuinely absent from
    // the roster. Matching on label was wrong — a device's Tailscale name and
    // its roster label routinely differ, so it added a duplicate of itself.
    if !nodes.contains(where: \.isSelf) {
      rows.insert(
        Reading(
          id: "self", label: selfLabel, rate: selfRate,
          tier: NodeTier.current(), reachable: true),
        at: 0)
    }
    // Reachable first, then by rate: a fast node that is down should not sit
    // above a slower one that is actually serving.
    return rows.sorted {
      if $0.reachable != $1.reachable { return $0.reachable }
      return $0.rate > $1.rate
    }
  }

  /// Only reachable nodes count. Summing a node that is down would report
  /// capacity the fleet does not have.
  private var aggregate: Double {
    readings.filter(\.reachable).reduce(0) { $0 + $1.rate }
  }

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
            // "—" and "down" are different facts: one node has simply not
            // generated yet, the other cannot be reached at all.
            Text(row.reachable ? (row.rate > 0 ? String(format: "%.1f", row.rate) : "—") : "down")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(
                !row.reachable ? Color.red : (row.rate > 0 ? Color.green : Color.secondary))
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
