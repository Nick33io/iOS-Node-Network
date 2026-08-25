import SwiftUI

/// One node on the board.
///
/// Collapsed it answers the only question worth asking across a whole fleet at
/// once: is this machine alive, and is it producing. Everything else — the
/// addresses, the memory, the controls — is a question you ask about one node,
/// so it lives behind the expand.
struct DeviceModule: View {
  let node: FleetNode
  let expanded: Bool
  let toggle: () -> Void
  let refresh: () -> Void
  let measure: () -> Void
  let testLink: () -> Void
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.top, 10)
        detail
      }
      Spacer(minLength: 0)
    }
    .padding(13)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(node.isNoteworthy ? node.signal.opacity(0.35) : Palette.hairline, lineWidth: 1)
    )
  }

  // MARK: Collapsed

  private var header: some View {
    HStack(spacing: 9) {
      Circle().fill(node.signal).frame(width: 7, height: 7)
      Text(node.label)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Palette.ink.opacity(0.92))
        .lineLimit(1)
      Spacer(minLength: 6)
      Text(rate)
        .font(.system(size: 14, weight: .light, design: .monospaced))
        .foregroundStyle((node.throughput ?? 0) > 0 ? Palette.live : Palette.faint)
        .contentTransition(.numericText())
        .lineLimit(1)
      Image(systemName: expanded ? "chevron.up" : "chevron.down")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(Palette.faint)
    }
    .contentShape(.rect)
    .onTapGesture(perform: toggle)
  }

  private var rate: String {
    guard let value = node.throughput, value > 0 else { return "—" }
    return String(format: "%.0f", value)
  }

  // MARK: Expanded

  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 5) {
        row("host", node.host)
        if let hardware = node.hardware { row("hardware", hardware) }
        if let memory = node.memoryGiB {
          row("memory", node.footprintGiB.map { String(format: "%.2f/%.0f GB", $0, memory) }
            ?? String(format: "%.0f GB", memory))
        }
        if let headroom = node.availableGiB { row("headroom", String(format: "%.1f GB", headroom)) }
        if let tier = node.tier { row("tier", tier.label) }
        if let model = node.model { row("model", model.split(separator: "/").last.map(String.init) ?? model) }
        if let backend = node.backend { row("backend", backend) }
        if let thermal = node.thermal { row("thermal", thermal, tint: node.isNoteworthy ? node.signal : nil) }
        if let power = node.power { row("power", power) }
        if let latency = node.probeMilliseconds { row("probe", "\(latency) ms") }
        if let link = node.link {
          row("link", link.summary)
        } else if node.isTestingLink {
          row("link", "measuring…")
        }
        if let detail = node.failureDetail {
          Text(detail)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(Palette.fault)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
        }
        controls
      }
      .padding(.top, 10)
    }
    .scrollIndicators(.never)
  }

  private func row(_ caption: String, _ value: String, tint: Color? = nil) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(caption)
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(Palette.faint)
        .frame(width: 62, alignment: .leading)
      Text(value)
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(tint ?? Palette.ink.opacity(0.72))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private var controls: some View {
    HStack(spacing: 7) {
      action("REFRESH", refresh, enabled: true)
      action("TOK/S", measure, enabled: node.isReachable)
      action("LINK", testLink, enabled: node.isReachable && !node.isTestingLink)
      Spacer(minLength: 0)
      action("REMOVE", remove, enabled: true, tint: Palette.fault)
    }
    .padding(.top, 9)
  }

  private func action(
    _ title: String, _ perform: @escaping () -> Void, enabled: Bool, tint: Color? = nil
  ) -> some View {
    Button(action: perform) {
      Text(title)
        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        .tracking(0.6)
        .foregroundStyle(enabled ? (tint ?? Palette.ink.opacity(0.62)) : Palette.faint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(enabled ? 0.05 : 0.02))
        )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}
