import NodeKit
import SwiftUI

/// The fleet at a glance, and one node in detail.
///
/// Landing on a node rather than opening to a summary is deliberate: the fleet
/// total is a number you check, but a node is a thing you watch, and which one
/// is worth watching depends on what you are doing. The choice persists, so the
/// window comes back where you left it.
///
/// Glass is used on three surfaces and nowhere else — the aggregate, the
/// roster rows, and the landed node's header. Everything else is a hairline on
/// black. Material on every panel flattens the hierarchy it is supposed to
/// create, and on a monitor the hierarchy is the product.
struct MonitorView: View {
  @State private var fleet = FleetManager()
  @State private var layout = BoardLayout()
  @State private var landedOn: String? = UserDefaults.standard.string(forKey: Self.landingKey)
  @State private var picking = false

  private static let landingKey = "nod3.monitor.landing"

  private var nodes: [FleetNode] { fleet.nodes.filter { $0.aliasOf == nil } }
  private var focused: FleetNode? {
    nodes.first { $0.host == landedOn } ?? nodes.first { $0.state == .reachable }
  }
  /// Only nodes reporting a live rate contribute. A node that has never
  /// generated reports nothing, and counting that as zero reads identically to
  /// a node that has stopped.
  private var throughput: Double { nodes.compactMap(\.throughput).reduce(0, +) }
  private var working: Int { nodes.filter { ($0.inFlight ?? 0) > 0 }.count }
  private var down: Int { nodes.filter { $0.state != .reachable }.count }

  var body: some View {
    ZStack {
      Palette.ground.ignoresSafeArea()
      HStack(spacing: 0) {
        roster
        Rectangle().fill(Palette.hairline).frame(width: 1)
        VStack(spacing: 0) {
          boardBar
          Rectangle().fill(Palette.hairline).frame(height: 1)
          BoardView(
            layout: layout,
            items: [.summary, .throughput] + nodes.map(BoardItem.node),
            fleet: fleet,
            selfLabel: Host.current().localizedName ?? "this Mac",
            refresh: { node in Task { await fleet.refresh(node) } },
            measure: { node in Task { await fleet.measure(node) } },
            testLink: { node in Task { await fleet.testLink(node) } },
            remove: { node in fleet.remove(node) }
          )
        }
      }
    }
    .task {
      fleet.startAutoRefresh()
      if landedOn == nil { picking = true }
    }
    .onDisappear { fleet.stopAutoRefresh() }
    .sheet(isPresented: $picking) { landingPicker }
  }

  // MARK: Roster

  private var roster: some View {
    GlassEffectContainer(spacing: 10) {
      VStack(alignment: .leading, spacing: 16) {
        Text("FLEET")
          .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
          .tracking(2.4)
          .foregroundStyle(Palette.faint)

        aggregate

        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            tier(.permanent, "always available", Palette.live)
            tier(.burst, "join when available", Palette.warn)
          }
        }
        .scrollIndicators(.never)
      }
      .padding(20)
    }
    .frame(width: 292)
  }

  private var aggregate: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(throughput > 0 ? String(format: "%.0f", throughput) : "—")
        .font(.system(size: 44, weight: .light, design: .monospaced))
        .foregroundStyle(throughput > 0 ? Palette.live : Palette.faint)
        .contentTransition(.numericText())
        .animation(.smooth(duration: 0.45), value: throughput)
        .lineLimit(1)
        .minimumScaleFactor(0.7)

      HStack(spacing: 5) {
        Text("tokens/sec")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(Palette.dim)
        if down > 0 {
          Text("· \(down) down")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.fault)
        } else if working > 0 {
          Text("· \(working) working")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.dim)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .glassEffect(.regular, in: .rect(cornerRadius: 14))
  }

  /// The roster, grouped the way the iPad console groups it. A tier with no
  /// members is omitted rather than shown empty — an empty heading reads as a
  /// fault when it only means this fleet has no phones attached today.
  @ViewBuilder
  private func tier(_ tier: NodeTier, _ caption: String, _ tint: Color) -> some View {
    let members = nodes.filter { tier == .permanent ? $0.tier == .permanent : $0.tier != .permanent }
    if !members.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Text(tier.label.uppercased())
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .tracking(1.8)
            .foregroundStyle(tint)
          Text(caption)
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(Palette.faint)
          Spacer(minLength: 0)
          Text("\(members.filter(\.isReachable).count)/\(members.count)")
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(Palette.dim)
        }
        ForEach(members) { node in
          RosterRow(node: node, landed: node.host == focused?.host)
            .onTapGesture { land(on: node) }
        }
      }
    }
  }

  // MARK: Board bar

  /// The landed node, and the two things you do to an arrangement.
  private var boardBar: some View {
    HStack(spacing: 14) {
      if let node = focused {
        Circle().fill(node.signal).frame(width: 7, height: 7)
        Text(node.label)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Palette.ink)
        Text([node.hardware, node.model?.split(separator: "/").last.map(String.init)]
          .compactMap { $0 }.joined(separator: "  ·  "))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(Palette.dim)
          .lineLimit(1)
      }
      Spacer(minLength: 12)
      Text("\(nodes.count) modules")
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(Palette.faint)
      Button {
        withAnimation(.smooth(duration: 0.3)) { layout.reset() }
      } label: {
        Text("RESET LAYOUT")
          .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
          .tracking(0.6)
          .foregroundStyle(Palette.ink.opacity(0.6))
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 13)
  }

  // MARK: Detail (unused while the board is the surface)

  @ViewBuilder
  private var detail: some View {
    if let node = focused {
      VStack(alignment: .leading, spacing: 20) {
        header(node)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
          Readout("throughput", node.throughput.map { String(format: "%.0f", $0) } ?? "—",
                  "tok/s", tint: (node.throughput ?? 0) > 0 ? Palette.live : nil)
          Readout("in flight", "\(node.inFlight ?? 0)", "requests")
          Readout("thermal", (node.thermal ?? "—").lowercased(), node.power ?? "",
                  tint: node.isNoteworthy ? node.signal : nil)
          Readout("memory", node.footprintGiB.map { String(format: "%.1f", $0) } ?? "—",
                  node.memoryGiB.map { String(format: "of %.0f GB", $0) } ?? "")
        }
        Spacer()
      }
      .padding(28)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      Text("no node")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Palette.faint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(_ node: FleetNode) -> some View {
    HStack(spacing: 12) {
      Circle().fill(node.signal).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 3) {
        Text(node.label)
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(Palette.ink)
        Text([node.hardware, node.model?.split(separator: "/").last.map(String.init)]
          .compactMap { $0 }.joined(separator: "  ·  "))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(Palette.dim)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .glassEffect(.regular, in: .rect(cornerRadius: 14))
  }

  // MARK: Landing

  private var landingPicker: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(alignment: .leading, spacing: 14) {
        Text("Land on")
          .font(.system(size: 19, weight: .medium))
          .foregroundStyle(Palette.ink)
        Text("The node this window opens to. Change it any time from the roster.")
          .font(.system(size: 11.5))
          .foregroundStyle(Palette.dim)
        ScrollView {
          VStack(spacing: 6) {
            ForEach(nodes) { node in
              RosterRow(node: node, landed: false)
                .onTapGesture { land(on: node); picking = false }
            }
          }
        }
        .frame(height: 236)
        .scrollIndicators(.never)
      }
      .padding(24)
    }
    .frame(width: 370)
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
      Circle().fill(node.signal).frame(width: 6, height: 6)
      VStack(alignment: .leading, spacing: 1) {
        Text(node.label)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Palette.ink.opacity(landed ? 1 : 0.72))
          .lineLimit(1)
        Text(node.hardware ?? node.host)
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(Palette.faint)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let rate = node.throughput, rate > 0 {
        Text(String(format: "%.0f", rate))
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Palette.live)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    // Tint only marks the landed row. A tint per state would put three colours
    // of glass in one column and turn the roster into a chart of itself.
    .glassEffect(landed ? .regular.tint(.white.opacity(0.09)) : .regular,
                 in: .rect(cornerRadius: 10))
    .contentShape(.rect)
  }
}

/// One measurement. No glass — these sit inside a detail pane that is already
/// distinguished, and material here would compete with the header rather than
/// support it.
private struct Readout: View {
  let caption: String
  let value: String
  let unit: String
  var tint: Color?

  init(_ caption: String, _ value: String, _ unit: String, tint: Color? = nil) {
    self.caption = caption
    self.value = value
    self.unit = unit
    self.tint = tint
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(caption.uppercased())
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .tracking(1.5)
        .foregroundStyle(Palette.faint)
      Text(value)
        .font(.system(size: 25, weight: .light, design: .monospaced))
        .foregroundStyle(tint ?? Palette.ink.opacity(0.88))
        .contentTransition(.numericText())
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      if !unit.isEmpty {
        Text(unit)
          .font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(Palette.faint)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(15)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.022))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
    )
  }
}
