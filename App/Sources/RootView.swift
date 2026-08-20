import SwiftUI
import WriteCore

struct RootView: View {
  @State private var model = RunModel()
  @State private var profile = DeviceProfile.current()

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          nodeSection
          egressSection
          runSection
          if !model.sections.isEmpty { outputSection }
        }
        .padding(20)
      }
      .background(Color.black)
      .navigationTitle("NODE")
      .navigationBarTitleDisplayMode(.inline)
    }
    .tint(.white)
    .task {
      // Test hook: lets a harness exercise a full run without driving the UI.
      guard ProcessInfo.processInfo.arguments.contains("-autorun") else { return }
      await model.run()
    }
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
        Button(model.isRunning ? "RUNNING" : "START") {
          Task { await model.run() }
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .disabled(model.isRunning)
      }
      .padding(.top, 6)
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
