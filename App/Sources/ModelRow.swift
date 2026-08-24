import SwiftUI

/// One catalogue entry.
///
/// Extracted from `ManagerView` because SwiftUI's type inference gives up on
/// deeply nested conditional views inside a ForEach, and the errors it emits
/// point nowhere near the cause.
struct ModelRow: View {
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
