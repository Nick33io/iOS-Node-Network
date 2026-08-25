import NodeKit
import SwiftUI

/// The fleet at a glance, and one node in detail.
///
/// Landing on a node rather than opening to a summary is deliberate: the fleet
/// total is a number you check, but a node is a thing you watch, and the one
/// worth watching differs by what you are doing. The choice persists, so the
/// window comes back where you left it.
struct MonitorView: View {
  @State private var fleet = FleetManager()
  @State private var landedOn: String? = UserDefaults.standard.string(forKey: Self.landingKey)
  @State private var picking = false
  @Namespace private var glass

  private static let landingKey = "nod3.monitor.landing"

  private var nodes: [FleetNode] { fleet.nodes.filter { $0.aliasOf == nil } }
  private var focused: FleetNode? {
    nodes.first { $0.host == landedOn } ?? nodes.first { $0.state == .reachable }
  }
  /// Only nodes reporting a live rate contribute. A node that has never
  /// generated reports nothing, and counting it as zero would read the same as
  /// a node that has stopped.
  private var fleetThroughput: Double {
    nodes.compactMap(\.throughput).reduce(0, +)
  }
  private var working: Int { nodes.filter { ($0.inFlight ?? 0) > 0 }.count }

  var body: some View {
    ZStack {
      background
      HStack(spacing: 0) {
        roster
        Divider().opacity(0.15)
        detail
      }
    }
    .task {
      fleet.startAutoRefresh()
      if landedOn == nil { picking = true }
    }
    .onDisappear { fleet.stopAutoRefresh() }
    .sheet(isPresented: $picking) { landingPicker }
  }

  // MARK: Ground

  /// A near-black ground with a single cool wash. Glass needs something behind
  /// it with structure — over a flat fill it reads as a grey rectangle, which
  /// is the whole material wasted.
  private var background: some View {
    LinearGradient(
      colors: [
        Color(red: 0.03, green: 0.04, blue: 0.06),
        Color(red: 0.06, green: 0.08, blue: 0.12),
        Color(red: 0.02, green: 0.03, blue: 0.05),
      ],
      startPoint: .topLeading, endPoint: .bottomTrailing
    )
    .overlay(alignment: .top) {
      Ellipse()
        .fill(Color(red: 0.20, green: 0.45, blue: 0.75).opacity(0.28))
        .frame(width: 780, height: 320)
        .blur(radius: 140)
        .offset(y: -150)
    }
    .ignoresSafeArea()
  }

  // MARK: Roster

  private var roster: some View {
    GlassEffectContainer(spacing: 14) {
      VStack(alignment: .leading, spacing: 14) {
        Text("FLEET")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .tracking(2.2)
          .foregroundStyle(.white.opacity(0.35))

        aggregate

        ScrollView {
          VStack(spacing: 8) {
            ForEach(nodes) { node in
              RosterRow(node: node, landed: node.host == focused?.host)
                .onTapGesture { land(on: node) }
            }
          }
        }
        .scrollIndicators(.never)
      }
      .padding(20)
    }
    .frame(width: 300)
  }

  private var aggregate: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(fleetThroughput > 0 ? String(format: "%.0f", fleetThroughput) : "—")
        .font(.system(size: 46, weight: .medium, design: .monospaced))
        .foregroundStyle(fleetThroughput > 0 ? Color(red: 0.42, green: 0.95, blue: 0.62) : .white.opacity(0.5))
        .contentTransition(.numericText())
        .animation(.smooth(duration: 0.5), value: fleetThroughput)
      Text(working > 0 ? "tokens/sec · \(working) working" : "tokens/sec · idle")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.4))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
  }

  // MARK: Detail

  @ViewBuilder
  private var detail: some View {
    if let node = focused {
      GlassEffectContainer(spacing: 16) {
        VStack(alignment: .leading, spacing: 18) {
          header(node)
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14
          ) {
            Readout("throughput", node.throughput.map { String(format: "%.0f", $0) } ?? "—", "tok/s")
            Readout("in flight", "\(node.inFlight ?? 0)", "requests")
            Readout("thermal", node.thermal ?? "—", node.power ?? "")
            Readout(
              "memory",
              node.footprintGiB.map { String(format: "%.1f", $0) } ?? "—",
              node.memoryGiB.map { String(format: "of %.0f GB", $0) } ?? ""
            )
          }
          Spacer()
        }
        .padding(28)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      Text("no node")
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white.opacity(0.3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(_ node: FleetNode) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Circle()
          .fill(node.state == .reachable ? Color(red: 0.42, green: 0.95, blue: 0.62) : .white.opacity(0.25))
          .frame(width: 7, height: 7)
        Text(node.label)
          .font(.system(size: 26, weight: .medium))
          .foregroundStyle(.white)
      }
      Text([node.hardware, node.model?.split(separator: "/").last.map(String.init)]
        .compactMap { $0 }.joined(separator: "  ·  "))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.4))
    }
  }

  // MARK: Landing

  private var landingPicker: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Land on")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.white)
      Text("The node this window opens to. Change it any time from the roster.")
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.45))
      ScrollView {
        VStack(spacing: 8) {
          ForEach(nodes) { node in
            RosterRow(node: node, landed: false)
              .onTapGesture { land(on: node); picking = false }
          }
        }
      }
      .frame(height: 240)
    }
    .padding(24)
    .frame(width: 380)
    .background(Color(red: 0.04, green: 0.05, blue: 0.08))
  }

  private func land(on node: FleetNode) {
    landedOn = node.host
    UserDefaults.standard.set(node.host, forKey: Self.landingKey)
  }
}

/// One node in the roster.
private struct RosterRow: View {
  let node: FleetNode
  let landed: Bool

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(node.state == .reachable
          ? ((node.inFlight ?? 0) > 0 ? Color(red: 0.42, green: 0.95, blue: 0.62) : .white.opacity(0.55))
          : .white.opacity(0.18))
        .frame(width: 6, height: 6)
      VStack(alignment: .leading, spacing: 2) {
        Text(node.label)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(landed ? 1 : 0.75))
          .lineLimit(1)
        Text(node.hardware ?? node.host)
          .font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.3))
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let rate = node.throughput, rate > 0 {
        Text(String(format: "%.0f", rate))
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Color(red: 0.42, green: 0.95, blue: 0.62))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .glassEffect(landed ? .regular.tint(.white.opacity(0.10)) : .regular, in: .rect(cornerRadius: 11))
    .contentShape(.rect)
  }
}

/// One measurement.
private struct Readout: View {
  let caption: String
  let value: String
  let unit: String

  init(_ caption: String, _ value: String, _ unit: String) {
    self.caption = caption
    self.value = value
    self.unit = unit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(caption.uppercased())
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(1.4)
        .foregroundStyle(.white.opacity(0.32))
      Text(value)
        .font(.system(size: 27, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .contentTransition(.numericText())
      if !unit.isEmpty {
        Text(unit)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.white.opacity(0.35))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .glassEffect(.regular, in: .rect(cornerRadius: 14))
  }
}
