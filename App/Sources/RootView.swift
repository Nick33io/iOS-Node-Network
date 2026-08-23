import NodeKit
import SwiftUI
import UIKit
import WriteCore

struct RootView: View {
  @State private var model = RunModel()
  @State private var profile = DeviceProfile.current()
  @State private var mesh = MeshPresence()
  @State private var server: NodeServer?
  /// Resting state while joined. Tapping the rain reveals the console; tapping
  /// the thumbnail puts it back.
  @State private var showingConsole = false
  @State private var ambient = AmbientDisplay()
  @State private var telemetry = NodeTelemetry()
  /// Whether the console shows instruments or the text produced so far.
  @State private var showingOutput = false
  #if canImport(AVFoundation) && !targetEnvironment(simulator)
    @State private var camera = CameraGlyphSource()
  #endif

  var body: some View {
    ZStack {
      if !showingConsole && currentFrame.columns > 0 {
        // A live signal beats a synthetic one: if a camera is feeding the
        // fleet, that is what the ambient screen should show.
        GlyphFieldView(frame: currentFrame)
          .transition(.opacity)
          .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showingConsole = true } }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Ambient camera display. Double tap to open the console.")
      } else if mesh.isJoined && !showingConsole {
        GeometryReader { proxy in
          MatrixRain(scale: MatrixRain.fitting(proxy.size))
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showingConsole = true } }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel("Joined to the node network. Double tap to open the console.")
      } else {
        console
          .transition(.opacity)
      }
    }
  }

  private var console: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if mesh.isJoined {
            matrixThumbnail
          }
          instrumentHeader
          instrumentsSection
          taskSection
          if showingOutput {
            outputSection
          }
          ambientSection
          serverSection
          meshSection
        }
        .padding(20)
      }
      .background(Color.black)
      .navigationTitle("NOD3")
      .navigationBarTitleDisplayMode(.inline)
    }
    .tint(.white)
    .task {
      telemetry.start { server?.servedBytes ?? 0 }
      // Test hook: lets a harness exercise a full run without driving the UI.
      guard ProcessInfo.processInfo.arguments.contains("-autorun") else { return }
      await model.run()
    }
  }

  /// Whichever frame this device should be showing — its own camera when it is
  /// the source, the followed node's otherwise.
  private var currentFrame: GlyphFrame {
    #if canImport(AVFoundation) && !targetEnvironment(simulator)
      if camera.isRunning { return camera.frame }
    #endif
    return ambient.frame
  }

  // MARK: Ambient

  private var ambientSection: some View {
    Panel(heading: "AMBIENT") {
      Row(key: "role", value: ambientLabel, tint: ambientTint)
      if currentFrame.columns > 0 {
        Row(key: "grid", value: "\(currentFrame.columns)x\(currentFrame.rows)")
        Row(key: "frame", value: "\(currentFrame.sequence)")
      }
      if let failure = ambient.lastError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(2)
      }
      HStack {
        Text("screen must stay awake — iOS suspends locked apps")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
        Spacer()
        Button(cameraRunning ? "STOP CAM" : "CAMERA") {
          Task { await toggleCamera() }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
      }
      .padding(.top, 6)
    }
  }

  private var cameraRunning: Bool {
    #if canImport(AVFoundation) && !targetEnvironment(simulator)
      return camera.isRunning
    #else
      return false
    #endif
  }

  private var ambientLabel: String {
    if cameraRunning { return "source" }
    switch ambient.role {
    case .viewer(let host): return "viewing \(host)"
    case .source: return "source"
    case .idle: return "off"
    }
  }

  private var ambientTint: Color {
    cameraRunning || currentFrame.columns > 0 ? .green : .secondary
  }

  @MainActor
  private func toggleCamera() async {
    #if canImport(AVFoundation) && !targetEnvironment(simulator)
      if camera.isRunning {
        camera.stop()
        // Stop pinning the screen awake the moment we stop needing it.
        UIApplication.shared.isIdleTimerDisabled = false
      } else {
        await camera.start()
        if camera.isRunning {
          // An ambient display that lets the screen lock stops being one.
          UIApplication.shared.isIdleTimerDisabled = true
          ensureServer().start()
          server?.provideGlyphs {
            guard camera.frame.columns > 0 else { return nil }
            return try? JSONEncoder().encode(camera.frame)
          }
        }
      }
    #endif
  }

  // MARK: Node server

  private var serverSection: some View {
    Panel(heading: "LISTENER") {
      Row(
        key: "state",
        value: server?.isListening == true ? "listening :8833" : "off",
        tint: server?.isListening == true ? .green : .secondary
      )
      if let served = server?.served, served > 0 {
        Row(key: "served", value: "\(served)")
      }
      if let failure = server?.lastError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(3)
      }
      HStack {
        Text("reachable over tailnet while open")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
        Spacer()
        Button(server?.isListening == true ? "STOP" : "LISTEN") {
          if server?.isListening == true {
            server?.stop()
          } else {
            ensureServer().start()
          }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
      }
      .padding(.top, 6)
    }
  }

  @discardableResult
  private func ensureServer() -> NodeServer {
    if let server { return server }
    let created = NodeServer(
      limits: MLXPolicy.limits,
      makeWriter: { try await model.writerForServing() },
      describe: {
        BridgeProfileEmitter.payload(
          node: mesh.localNode.raw,
          label: UIDevice.current.name,
          backend: model.backend.label,
          model: model.backend == .onDevice ? MLXPolicy.allowedModel : model.writerModel,
          limits: MLXPolicy.limits
        )
      }
    )
    server = created
    return created
  }

  // MARK: Mesh

  /// Tapping this returns the device to the ambient rain.
  private var matrixThumbnail: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.25)) { showingConsole = false }
    } label: {
      HStack(spacing: 12) {
        MatrixRain(scale: 0.4)
          .frame(width: 54, height: 40)
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .allowsHitTesting(false)
        VStack(alignment: .leading, spacing: 2) {
          Text("JOINED")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.green)
          Text(mesh.peers.isEmpty ? "no peers yet" : "\(mesh.peers.count) peer(s)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        Spacer()
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Return to the node network display")
  }

  private var meshSection: some View {
    Panel(heading: "MESH") {
      Row(key: "identity", value: mesh.localNode.raw)
      Row(
        key: "peer-to-peer",
        value: mesh.isJoined ? "joined" : "off",
        tint: mesh.isJoined ? .green : .secondary
      )
      if mesh.isJoined {
        Row(key: "peers", value: "\(mesh.peers.count)")
      }

      HStack {
        Text(mesh.isJoined ? "leaving stops discovery" : "use when there is no Wi-Fi")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
        Spacer()
        Button(mesh.isJoined ? "LEAVE" : "JOIN") {
          if mesh.isJoined {
            mesh.leave()
          } else {
            mesh.join()
          }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .disabled(!mesh.isAvailable)
      }
      .padding(.top, 6)
    }
  }

  // MARK: Instruments

  private var isConnected: Bool {
    server?.isListening == true || mesh.isJoined
  }

  private var instrumentHeader: some View {
    HStack(spacing: 10) {
      StatusDot(isUp: isConnected)
      Text(profile.identifier)
        .font(.system(.callout, design: .monospaced).weight(.semibold))
      Spacer()
      Text(isConnected ? "ONLINE" : "OFFLINE")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(isConnected ? .green : .red)
    }
  }

  private var instrumentsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Meter(
        key: "memory",
        value: telemetry.footprintLabel,
        fraction: telemetry.memoryFraction,
        warnAbove: 0.7
      )
      Meter(
        key: "thermal",
        value: telemetry.thermalLabel,
        fraction: telemetry.thermalFraction,
        warnAbove: 0.5
      )
      Meter(
        key: "power",
        value: telemetry.powerLabel,
        fraction: telemetry.powerFraction,
        // Low power is the warning here, so the usual high-is-bad rule is
        // inverted — handled by tint rather than a threshold.
        tint: telemetry.powerFraction < 0.2 ? .orange : .green
      )
      Meter(
        key: "bandwidth",
        value: telemetry.bandwidthLabel,
        fraction: telemetry.bandwidthFraction
      )
      // Passive bandwidth above is what this node is currently serving; the
      // link test below is what the connection can actually carry. A quiet
      // node reads 0 B/s on the first and may still have a fast link.
      if let link = model.link {
        Meter(
          key: "link down",
          value: String(format: "%.1f MB/s", link.downloadMBps),
          // 12 MB/s tops a good Wi-Fi path here; a relayed one lands far below.
          fraction: min(1, link.downloadMBps / 12)
        )
        Meter(
          key: "link up",
          value: String(format: "%.1f MB/s", link.uploadMBps),
          fraction: min(1, link.uploadMBps / 12)
        )
        Row(key: "latency", value: "\(link.latencyMilliseconds) ms")
      }
      if let failure = model.linkError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(2)
      }
      HStack {
        Text("to \(model.host)")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
        Spacer()
        Button(model.isTestingLink ? "TESTING" : "LINK TEST") {
          Task { await model.runLinkTest() }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .disabled(model.isTestingLink)
      }
      .padding(.top, 2)
    }
  }

  // MARK: Task

  private var taskSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("TASK")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .tracking(2)

      Meter(
        key: "throughput",
        value: String(format: "%.1f tok/s", liveRate),
        // 80 tok/s tops this fleet; a fixed ceiling keeps the bar comparable
        // between runs and between devices.
        fraction: min(1, liveRate / 80)
      )
      Row(key: "tokens", value: "\(model.tokensThisRun)")
      Row(key: "sections", value: "\(model.sections.count)")
      Row(key: "status", value: statusText, tint: statusTint)

      HStack(spacing: 14) {
        Button("BENCH") { Task { await model.runBenchmark() } }
          .disabled(model.isRunning)
        Button(model.isRunning ? "RUNNING" : "START") { Task { await model.run() } }
          .fontWeight(.semibold)
          .disabled(model.isRunning)
        Spacer()
        Button(showingOutput ? "HIDE TEXT" : "SHOW TEXT") {
          withAnimation(.easeInOut(duration: 0.2)) { showingOutput.toggle() }
        }
        .disabled(model.sections.isEmpty)
      }
      .font(.system(.caption, design: .monospaced))

      if let bench = model.benchmark {
        Row(key: "measured", value: String(format: "%.1f tok/s", bench.tokensPerSecond), tint: .green)
      }
      if let failure = model.benchmarkError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(4)
      }
    }
  }

  /// Live rate while running, last measured rate otherwise, so the meter does
  /// not drop to zero the moment a task ends.
  private var liveRate: Double {
    model.isRunning && model.tokensPerSecondLive > 0
      ? model.tokensPerSecondLive
      : (model.benchmark?.tokensPerSecond ?? model.tokensPerSecondLive)
  }

  // MARK: Node

  private var nodeSection: some View {
    Panel(heading: "NODE") {
      Row(key: "hardware", value: profile.identifier)
      Row(key: "memory", value: String(format: "%.0f GB", profile.memoryGB))
      Row(key: "thermal", value: profile.thermalLabel)
      Row(key: "power", value: profile.powerLabel)
      Row(
        key: "long work",
        value: profile.suitedToLongWork ? "eligible" : "short leases",
        tint: profile.suitedToLongWork ? .green : .yellow
      )
    }
  }

  // MARK: Egress

  private var egressSection: some View {
    Panel(heading: "EGRESS") {
      Row(key: "planner sees", value: "placeholders only")
      Row(key: "values stay", value: "on device")
      if let facts = model.facts {
        Row(key: "facts held", value: "\(facts.facts.count)")
      }
    }
  }

  // MARK: Run

  private var runSection: some View {
    Panel(heading: "RUN") {
      Row(key: "host", value: model.host)
      Row(key: "planner", value: model.plannerModel)
      Row(
        key: "writer",
        value: model.backend == .onDevice ? MLXPolicy.allowedModel : model.writerModel
      )
      Row(
        key: "backend",
        value: model.backend.label,
        tint: model.backend == .onDevice ? .green : .yellow
      )
      if !WriterBackend.supportsOnDevice {
        Row(key: "on-device", value: WriterBackend.unavailableReason, tint: .secondary)
      }

      HStack {
        Text(statusText)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(statusTint)
        Spacer()
        Button("BENCH") {
          Task { await model.runBenchmark() }
        }
        .font(.system(.caption, design: .monospaced))
        .disabled(model.isRunning)
        Button(model.isRunning ? "RUNNING" : "START") {
          Task { await model.run() }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .disabled(model.isRunning)
      }
      .padding(.top, 6)

      if let bench = model.benchmark {
        Row(key: "speed", value: String(format: "%.1f tok/s", bench.tokensPerSecond), tint: .green)
        Row(key: "elapsed", value: String(format: "%.1fs", bench.seconds))
        Row(key: "output", value: "\(bench.outputCharacters) chars")
      }
      if let failure = model.benchmarkError {
        Text(failure)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.red)
          .lineLimit(4)
          .padding(.top, 4)
      }
    }
  }

  private var statusText: String {
    switch model.phase {
    case .idle: return "idle"
    case .loading: return "loading model \(Int(model.loadProgress * 100))%"
    case .planning: return "planning…"
    case .writing: return "writing \(model.sections.count) done"
    case .finished(let seconds): return "complete in \(seconds)s"
    case .failed(let message): return String(message.prefix(90))
    }
  }

  private var statusTint: Color {
    switch model.phase {
    case .failed: return .red
    case .finished: return .green
    default: return .secondary
    }
  }

  // MARK: Output

  private var outputSection: some View {
    Panel(heading: model.title.isEmpty ? "OUTPUT" : model.title.uppercased()) {
      ForEach(model.sections, id: \.id) { section in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(section.heading)
              .font(.system(.caption, design: .monospaced).weight(.semibold))
            Spacer()
            Text(section.isClean ? "clean" : "\(section.issues.count) issue")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(section.isClean ? .green : .yellow)
          }
          Text(section.text)
            .font(.system(.footnote, design: .default))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
      }
    }
  }
}

// MARK: Chrome

private struct Panel<Content: View>: View {
  let heading: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(heading)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .tracking(2)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct Row: View {
  let key: String
  let value: String
  var tint: Color = .primary

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(key)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(tint)
    }
  }
}
