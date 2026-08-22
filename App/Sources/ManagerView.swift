import SwiftUI
import UIKit
import NodeKit

/// The iPad's fleet console.
struct ManagerView: View {
  @State private var fleet = FleetManager()
  @State private var showingAdd = false
  @State private var newLabel = ""
  @State private var newHost = ""
  /// Ambient resting state, same idiom as a worker node: the fleet is up and
  /// has nothing to ask of anyone. Tap to bring the console back.
  @State private var showingRain = false
  @State private var ambient = AmbientDisplay()
  #if canImport(AVFoundation) && !targetEnvironment(simulator)
    @State private var camera = CameraGlyphSource()
  #endif

  private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

  var body: some View {
    ZStack {
      if showingRain {
        GeometryReader { proxy in
          MatrixRain(scale: MatrixRain.fitting(proxy.size))
            .onTapGesture {
              withAnimation(.easeInOut(duration: 0.25)) { showingRain = false }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Fleet display. Double tap to open the console.")
        }
        .ignoresSafeArea()
        .transition(.opacity)
      } else {
        console.transition(.opacity)
      }
    }
  }

  private var console: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          summary
          LazyVGrid(columns: columns, spacing: 16) {
            ForEach(fleet.nodes) { node in
              NodeCard(
                node: node,
                refresh: { Task { await fleet.refresh(node) } },
                measure: { Task { await fleet.measure(node) } },
                remove: { fleet.remove(node) }
              )
            }
          }
        }
        .padding(20)
      }
      .background(Color.black)
      .navigationTitle("NOD3 · FLEET")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            Task { await toggleCamera() }
          } label: {
            Image(systemName: cameraRunning ? "video.fill" : "video")
          }
          .accessibilityLabel(cameraRunning ? "Stop camera" : "Start ambient camera")
          Button {
            fleet.restoreDefaults()
            Task { await fleet.refreshAll() }
          } label: {
            Image(systemName: "arrow.counterclockwise.circle")
          }
          .accessibilityLabel("Restore default nodes")
          Button {
            withAnimation(.easeInOut(duration: 0.25)) { showingRain = true }
          } label: {
            Image(systemName: "square.grid.3x3.fill")
          }
          .accessibilityLabel("Fleet display")
          Button {
            showingAdd = true
          } label: {
            Image(systemName: "plus")
          }
          Button {
            Task { await fleet.measureAll() }
          } label: {
            Image(systemName: "speedometer")
          }
          .disabled(fleet.isRefreshing)
          Button {
            Task { await fleet.refreshAll() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(fleet.isRefreshing)
        }
      }
      .task {
        await fleet.refreshAll()
      }
      .sheet(isPresented: $showingAdd) { addSheet }
    }
    .tint(.green)
    .preferredColorScheme(.dark)
  }

  /// This device's own camera when it is the source, the followed node's
  /// otherwise.
  private var currentFrame: GlyphFrame {
    #if canImport(AVFoundation) && !targetEnvironment(simulator)
      if camera.isRunning { return camera.frame }
    #endif
    return ambient.frame
  }

  private var cameraRunning: Bool {
    #if canImport(AVFoundation) && !targetEnvironment(simulator)
      return camera.isRunning
    #else
      return false
    #endif
  }

  @MainActor
  private func toggleCamera() async {
    #if canImport(AVFoundation) && !targetEnvironment(simulator)
      if camera.isRunning {
        camera.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        withAnimation(.easeInOut(duration: 0.25)) { showingRain = false }
      } else {
        await camera.start()
        if camera.isRunning {
          // An ambient display that lets the screen lock stops being one.
          UIApplication.shared.isIdleTimerDisabled = true
          withAnimation(.easeInOut(duration: 0.25)) { showingRain = true }
        }
      }
    #endif
  }

  private var summary: some View {
    HStack(spacing: 28) {
      Stat(
        key: "nodes up",
        value: "\(fleet.reachableCount)/\(fleet.nodes.count)",
        tint: fleet.reachableCount > 0 ? .green : .red
      )
      Stat(
        key: "fleet throughput",
        value: fleet.aggregateTokensPerSecond > 0
          ? String(format: "%.0f tok/s", fleet.aggregateTokensPerSecond) : "unmeasured",
        tint: fleet.aggregateTokensPerSecond > 0 ? .green : .secondary
      )
      if let swept = fleet.lastSweep {
        Stat(key: "last sweep", value: swept.formatted(date: .omitted, time: .standard))
      }
      if currentFrame.columns > 0 {
        Stat(
          key: "ambient",
          value: cameraRunning ? "source" : "viewing",
          tint: .green
        )
      }
      Spacer()
      if fleet.isRefreshing { ProgressView().tint(.green) }
    }
  }

  private var addSheet: some View {
    NavigationStack {
      Form {
        // Tapping a name is the fast path. The catalogue is the tailnet, so
        // the common case needs no typing at all.
        Section("on this tailnet") {
          ForEach(unlistedKnownNodes) { entry in
            Button {
              fleet.add(label: entry.label, host: entry.host)
              showingAdd = false
              Task { await fleet.refreshAll() }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.label)
                    .font(.system(.body, design: .monospaced))
                  Text("\(entry.host) · \(entry.platform)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle")
                  .foregroundStyle(.green)
              }
            }
            .buttonStyle(.plain)
          }
          if unlistedKnownNodes.isEmpty {
            Text("every known node is already listed")
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
        }

        // The catalogue is a convenience, not a source of truth: a device
        // re-added to the tailnet gets a new address, and not every node will
        // ever be on this list.
        Section("by label or address") {
          TextField("e.g. fold, 17 pro, or 100.x.x.x", text: $newHost)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
          if let match = KnownNodes.resolve(newHost) {
            HStack {
              Text("→ \(match.label)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
              Spacer()
              Text(match.host)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          } else if !newHost.isEmpty {
            Text("no match — enter a full address")
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle("Add node")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            if let match = KnownNodes.resolve(newHost) {
              fleet.add(label: match.label, host: match.host)
            }
            newLabel = ""
            newHost = ""
            showingAdd = false
            Task { await fleet.refreshAll() }
          }
          .disabled(KnownNodes.resolve(newHost) == nil)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            newHost = ""
            showingAdd = false
          }
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  /// Catalogue entries not already in the roster. Offering a node that is
  /// already listed just invites a duplicate.
  private var unlistedKnownNodes: [KnownNodes.Entry] {
    KnownNodes.all.filter { entry in !fleet.nodes.contains { $0.host == entry.host } }
  }
}

private struct NodeCard: View {
  let node: FleetNode
  let refresh: () -> Void
  let measure: () -> Void
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
        Text(node.label)
          .font(.system(.callout, design: .monospaced).weight(.semibold))
        Spacer()
        Text(statusText)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(statusColor)
      }

      // The headline number. Shown as a bar so a glance across the grid reads
      // as relative capacity rather than a column of digits to compare.
      if let rate = node.tokensPerSecond {
        VStack(alignment: .leading, spacing: 4) {
          Text(String(format: "%.1f tok/s", rate))
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .foregroundStyle(.green)
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Rectangle().fill(.white.opacity(0.08))
              Rectangle()
                .fill(.green.opacity(0.75))
                // 120 tok/s is the top of the scale seen on this fleet; a fixed
                // ceiling keeps bars comparable between refreshes.
                .frame(width: proxy.size.width * min(1, rate / 120))
            }
          }
          .frame(height: 4)
        }
      } else {
        Text("unmeasured")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      Divider().overlay(.white.opacity(0.1))

      Field("host", node.host)
      if let hardware = node.hardware { Field("hardware", hardware) }
      if let memory = node.memoryGiB { Field("memory", String(format: "%.0f GiB", memory)) }
      if let model = node.model { Field("model", model) }
      if let backend = node.backend { Field("backend", backend) }
      if let thermal = node.thermal { Field("thermal", thermal) }
      if let power = node.power { Field("power", power) }
      if let latency = node.probeMilliseconds { Field("probe", "\(latency) ms") }
      if let detail = node.failureDetail {
        Text(detail)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red.opacity(0.85))
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 2)
      }

      HStack(spacing: 14) {
        Button("REFRESH", action: refresh)
        Button("MEASURE", action: measure).disabled(!node.isReachable)
        Spacer()
        Button(role: .destructive, action: remove) { Text("REMOVE") }
      }
      .font(.system(.caption2, design: .monospaced))
      .buttonStyle(.plain)
      .padding(.top, 4)
    }
    .padding(16)
    // An offline node reports almost nothing, so its card would be a third the
    // height of a healthy one and the grid would read as broken rather than as
    // a fleet with something wrong in it. A floor keeps the rows even.
    .frame(minHeight: 250, alignment: .top)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }

  private var statusColor: Color {
    if node.aliasOf != nil { return .orange }
    switch node.state {
    case .reachable: return .green
    case .idle: return .yellow
    case .unreachable: return .red
    case .unknown: return .gray
    }
  }

  private var statusText: String {
    if let owner = node.aliasOf { return "same as \(owner)" }
    switch node.state {
    case .reachable: return "up"
    // A node on battery reports suitedToLongWork false: available, but not for
    // work that will outlive its charge.
    case .idle: return "short leases"
    case .unreachable(let why): return why
    case .unknown: return "unknown"
    }
  }
}

private struct Field: View {
  let key: String
  let value: String
  init(_ key: String, _ value: String) {
    self.key = key
    self.value = value
  }
  var body: some View {
    HStack {
      Text(key)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.system(.caption2, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

private struct Stat: View {
  let key: String
  let value: String
  var tint: Color = .primary
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(key)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.system(.title3, design: .monospaced).weight(.semibold))
        .foregroundStyle(tint)
    }
  }
}
