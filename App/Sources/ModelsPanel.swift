import SwiftUI

/// Weights on disk and in memory, for any node.
///
/// Shared between the phone and the manager rather than living only on the
/// iPad: a node that selects a model automatically still has to be able to
/// fetch it, and a phone with no way to download is a node that can never do
/// the work it was assigned.
struct ModelsPanel: View {
  @Bindable var models: ModelStore
  let download: (ModelStore.Entry) -> Void
  let load: (ModelStore.Entry) -> Void
  let unload: () -> Void

  var body: some View {
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
          download: { download(entry) },
          load: { load(entry) },
          unload: unload,
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
      // The ceiling every row is measured against. Shown once here rather than
      // repeated per row, since it is a property of the device.
      Text("headroom \(String(format: "%.2f GB", Double(MLXPolicy.availableMemoryBytes) / 1_073_741_824))")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
  }
}
