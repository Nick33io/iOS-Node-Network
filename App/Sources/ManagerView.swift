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
  // The iPad is the largest mobile device here; leaving it as an observer
  // wastes the node with the most headroom. It manages and serves.
  @State private var node = RunModel()
  @State private var telemetry = NodeTelemetry()
  @State private var server: NodeServer?
  @State private var models = ModelStore()
  #if canImport(MLX) && !targetEnvironment(simulator)
    @State private var writer = MLXWriter()
  #endif
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
          selfNodePanel
          modelsPanel
          tierSection(.permanent, caption: "always available")
          tierSection(.burst, caption: "join when available")
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
          .accessibilityLabel("Measure throughput on every node")
          .disabled(fleet.isRefreshing)
          Button {
            Task { await fleet.testAllLinks() }
          } label: {
            Image(systemName: "network")
          }
          .accessibilityLabel("Test the link to every node")
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
        telemetry.start { server?.servedBytes ?? 0 }
        // Serve by default: a manager that has to be told to contribute is a
        // manager that mostly does not.
        ensureServer().start()
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

  /// This device acting as a node, alongside its role as manager.
  private var selfNodePanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        StatusDot(isUp: server?.isListening == true)
        Text("THIS DEVICE")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .tracking(2)
        Spacer()
        Text(server?.isListening == true ? "SERVING :8833" : "NOT SERVING")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(server?.isListening == true ? .green : .secondary)
      }

      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          Meter(
            key: "memory", value: telemetry.footprintLabel,
            fraction: telemetry.memoryFraction, warnAbove: 0.7)
          Meter(
            key: "thermal", value: telemetry.thermalLabel,
            fraction: telemetry.thermalFraction, warnAbove: 0.5)
        }
        VStack(alignment: .leading, spacing: 12) {
          Meter(
            key: "power", value: telemetry.powerLabel,
            fraction: telemetry.powerFraction)
          Meter(
            key: "bandwidth", value: telemetry.bandwidthLabel,
            fraction: telemetry.bandwidthFraction)
        }
      }

      Meter(
        key: "throughput",
        value: selfRate > 0 ? String(format: "%.1f tok/s", selfRate) : "unmeasured",
        // Same 80 tok/s ceiling the phone panel and the node cards use, so a
        // glance across manager, self, and fleet compares like for like.
        fraction: min(1, selfRate / 80)
      )
      if server?.tokensServed ?? 0 > 0 {
        HStack {
          Text("tokens served")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(server?.tokensServed ?? 0)")
            .font(.system(.caption2, design: .monospaced))
        }
      }

      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(MLXPolicy.allowedModel)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
          if !MLXPolicy.hasIncreasedMemoryLimit {
            Text("increased-memory-limit not granted — capped to a smaller model")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.orange)
          }
        }
        Spacer()
        Button("MEASURE") {
          Task { await node.runBenchmark() }
        }
        .font(.system(.caption, design: .monospaced))
        .disabled(node.isRunning)
        Button(server?.isListening == true ? "STOP" : "SERVE") {
          if server?.isListening == true {
            server?.stop()
          } else {
            ensureServer().start()
          }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
      }
      if let failure = server?.lastError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(2)
      }
    }
    .padding(16)
    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
  }

  /// Live rate while serving, falling back to this device's own benchmark so
  /// the meter reads something before anyone has dispatched work here.
  private var selfRate: Double {
    let served = server?.lastTokensPerSecond ?? 0
    if served > 0 { return served }
    return node.benchmark?.tokensPerSecond ?? node.tokensPerSecondLive
  }

  @discardableResult
  private func ensureServer() -> NodeServer {
    if let server { return server }
    let created = NodeServer(
      limits: MLXPolicy.limits,
      makeWriter: { try await node.writerForServing() },
      describe: {
        BridgeProfileEmitter.payload(
          node: BridgeProfileEmitter.nodeIdentity,
          label: UIDevice.current.name,
          backend: node.backend.label,
          model: node.backend == .onDevice ? MLXPolicy.allowedModel : node.writerModel,
          limits: MLXPolicy.limits
        )
      }
    )
    server = created
    return created
  }

  /// Weights on disk and in memory.
  private var modelsPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("MODELS")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .tracking(2)
        Spacer()
        Text("\(models.diskLabel) · \(models.freeSpaceLabel)")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      ForEach(models.entries) { entry in
        ModelRow(
          entry: entry,
          isLoaded: models.loadedModelID == entry.id,
          isBusy: models.busyModelID == entry.id,
          anyBusy: models.busyModelID != nil,
          progress: models.progress,
          download: { Task { await downloadModel(entry) } },
          load: { Task { await loadModel(entry) } },
          unload: { unloadModel() },
          evict: { models.evict(entry) }
        )
      }

      if !models.status.isEmpty {
        Text(models.status)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.green)
      }
      if let failure = models.lastError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(3)
      }
      Text("headroom \(String(format: "%.2f GB", Double(MLXPolicy.availableMemoryBytes) / 1_073_741_824))")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
  }

  private func downloadModel(_ entry: ModelStore.Entry) async {
    #if canImport(MLX) && !targetEnvironment(simulator)
      await models.download(entry, using: writer)
    #else
      models.lastError = "MLX is unavailable in this build"
    #endif
  }

  private func loadModel(_ entry: ModelStore.Entry) async {
    #if canImport(MLX) && !targetEnvironment(simulator)
      await models.load(entry, using: writer)
    #else
      models.lastError = "MLX is unavailable in this build"
    #endif
  }

  private func unloadModel() {
    #if canImport(MLX) && !targetEnvironment(simulator)
      models.unload(using: writer)
    #endif
  }

  /// One tier's nodes.
  ///
  /// Split rather than mixed because the two behave differently enough that a
  /// single list misleads: an offline permanent node is a fault, an offline
  /// burst node is just a phone in someone's pocket.
  @ViewBuilder
  private func tierSection(_ tier: NodeTier, caption: String) -> some View {
    let members = fleet.nodes(in: tier)
    if !members.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Text(tier.label.uppercased())
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(tier == .permanent ? .green : .yellow)
            .tracking(2)
          Text(caption)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
          Spacer()
          Text("\(members.filter(\.isReachable).count)/\(members.count) up")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(members) { node in
            NodeCard(
              node: node,
              refresh: { Task { await fleet.refresh(node) } },
              measure: { Task { await fleet.measure(node) } },
              testLink: { Task { await fleet.testLink(node) } },
              remove: { fleet.remove(node) }
            )
          }
        }
      }
    }
  }

  private var summary: some View {
    HStack(spacing: 28) {
      Stat(
        key: "permanent",
        value: "\(fleet.permanentUp)",
        tint: fleet.permanentUp > 0 ? .green : .red
      )
      Stat(
        key: "burst",
        value: "\(fleet.burstUp)",
        tint: fleet.burstUp > 0 ? .yellow : .secondary
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
  let testLink: () -> Void
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
      if let memory = node.memoryGiB {
        Field(
          "memory",
          node.footprintGiB.map { String(format: "%.2f/%.0f GB", $0, memory) }
            ?? String(format: "%.0f GB", memory)
        )
      }
      if let headroom = node.availableGiB {
        Field("headroom", String(format: "%.1f GB", headroom))
      }
      if let tier = node.tier { Field("tier", tier.label) }
      if let model = node.model { Field("model", model) }
      if let backend = node.backend { Field("backend", backend) }
      if let thermal = node.thermal { Field("thermal", thermal) }
      if let power = node.power { Field("power", power) }
      if let latency = node.probeMilliseconds { Field("probe", "\(latency) ms") }
      if let link = node.link {
        Field("link", link.summary)
      } else if node.isTestingLink {
        Field("link", "measuring…")
      }
      if let detail = node.failureDetail {
        Text(detail)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red.opacity(0.85))
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 2)
      }

      HStack(spacing: 12) {
        Button("REFRESH", action: refresh)
        Button("TOK/S", action: measure).disabled(!node.isReachable)
        Button("LINK", action: testLink).disabled(!node.isReachable || node.isTestingLink)
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
    if node.isSelf { return "this device" }
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


/// One catalogue entry.
///
/// Extracted from `ManagerView` because SwiftUI's type inference gives up on
/// deeply nested conditional views inside a ForEach, and the errors it emits
/// point nowhere near the cause.
private struct ModelRow: View {
  let entry: ModelStore.Entry
  let isLoaded: Bool
  let isBusy: Bool
  let anyBusy: Bool
  let progress: Double
  let download: () -> Void
  let load: () -> Void
  let unload: () -> Void
  let evict: () -> Void

  private var fits: Bool { MLXPolicy.canHost(entry.model) }

  private var dotColor: Color {
    if isLoaded { return .green }
    return entry.isDownloaded ? .green.opacity(0.35) : .gray.opacity(0.4)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Circle().fill(dotColor).frame(width: 7, height: 7)
        Text(entry.shortName)
          .font(.system(.caption, design: .monospaced).weight(.medium))
        Spacer()
        // Disk size and resident requirement are different numbers and both
        // matter: one decides whether it downloads, the other whether it runs.
        Text("\(entry.sizeLabel) · needs \(entry.residentLabel)")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(fits ? Color.secondary : Color.orange)
      }

      if isBusy {
        ProgressView(value: progress).tint(.green)
      }

      HStack(spacing: 12) {
        if !entry.isDownloaded {
          Button("DOWNLOAD", action: download).disabled(anyBusy)
        } else if isLoaded {
          Button("UNLOAD", action: unload)
        } else {
          Button("LOAD", action: load).disabled(anyBusy || !fits)
        }
        if entry.isDownloaded {
          Button("EVICT", action: evict).disabled(anyBusy || isLoaded)
        }
        Spacer()
        if !fits {
          Text("exceeds headroom")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.orange)
        }
      }
      .font(.system(.caption2, design: .monospaced))
      .buttonStyle(.plain)
    }
    .padding(.vertical, 6)
  }
}
